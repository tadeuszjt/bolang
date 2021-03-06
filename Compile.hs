{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Compile where

import Data.List
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Short as BSS
import Control.Monad
import Control.Monad.State
import Control.Monad.IO.Class
import Control.Monad.Fail hiding (fail)
import Control.Monad.Except hiding (void, fail)
import Foreign.Ptr

import LLVM.AST.Name
import qualified LLVM.AST as LL
import qualified LLVM.AST.Type as LL
import qualified LLVM.AST.Constant as C
import qualified LLVM.Internal.FFI.DataLayout as FFI
import LLVM.AST.Global
import LLVM.IRBuilder.Instruction       
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Module
import LLVM.IRBuilder.Monad
import LLVM.Context

import qualified AST as S
import qualified Flatten as F
import Monad
import Type
import Error
import Value
import CompileState
import Print
import Funcs
import Table
import ADT

mkBSS = BSS.toShort . BS.pack


compileFlatState
    :: BoM s m
    => Context
    -> Ptr FFI.DataLayout
    -> Map.Map S.Path CompileState
    -> F.FlattenState
    -> m CompileState
compileFlatState ctx dl imports flatState = do
    res <- runBoMT (initCompileState ctx dl imports) (runModuleCmpT emptyModuleBuilder cmp)
    case res of
        Left err                 -> throwError err
        Right ((_, defs), state) -> return $ state { definitions = defs }
    where
            cmp :: (MonadFail m, Monad m, MonadIO m) => ModuleCmpT CompileState m ()
            cmp = void $ func "main" [] LL.VoidType $ \_ -> do
                    forM_ (Map.toList $ F.typeDefs flatState) $ \(flat, (pos, typ)) ->
                        cmpTypeDef (S.Typedef pos flat typ)
                    mapM_ cmpFuncHdr (F.funcDefs flatState)
                    mapM_ cmpExternDef (F.externDefs flatState)
                    mapM_ cmpVarDef (F.varDefs flatState)
                    mapM_ cmpFuncDef (F.funcDefs flatState)


cmpTypeDef :: InsCmp CompileState m => S.Stmt -> m ()
cmpTypeDef (S.Typedef pos sym typ) = withPos pos $ do
    let typdef = Typedef sym

    forM_ [KeyFunc [], KeyFunc [typ], KeyFunc [typdef]] $ \key -> do
        checkSymKeyUndef sym key
        addObj sym key (ObjConstructor typdef)

    if isTuple typ || isTable typ || isADT typ
    then do
        name <- freshName (mkBSS sym)
        addSymKeyDec sym KeyType name . DecType =<< opTypeOf typ
        checkSymKeyUndef sym KeyType
        addObj sym KeyType $ ObType typ (Just name)
    else do
        checkSymKeyUndef sym KeyType
        addObj sym KeyType $ ObType typ Nothing

    case typ of
        ADT ts -> do
            forM_ ts $ \t -> case t of
                Named s t -> do
                    checkSymKeyUndef s (KeyFunc [ADT [t]])
                    addObj s (KeyFunc [t]) (ObjPtrFieldCons typdef)
                t -> do
                    checkSymKeyUndef sym (KeyFunc [t])
                    addObj sym (KeyFunc [t]) (ObjConstructor typdef)


        _ -> return ()


cmpVarDef :: InsCmp CompileState m => S.Stmt -> m ()
cmpVarDef (S.Assign pos (S.PatIdent p sym) expr) = do
    val <- cmpExpr expr

    checkSymKeyUndef sym KeyVar
    name <- freshName (mkBSS sym)
    
    let typ = valType val
    opTyp <- opTypeOf typ

    if isCons (valOp val)
    then do
        loc <- Ptr typ <$> global name opTyp (toCons $ valOp val)
        addObj sym KeyVar (ObjVal loc)
    else do
        initialiser <- zeroOf typ
        loc <- Ptr typ <$> global name opTyp (toCons $ valOp initialiser)
        valStore loc val
        addObj sym KeyVar (ObjVal loc)

    addSymKeyDec sym KeyVar name (DecVar opTyp)
    addDeclared name


cmpExternDef :: InsCmp CompileState m => S.Stmt -> m ()
cmpExternDef (S.Extern pos sym params retty) = do
    checkSymUndef sym 
    let name = LL.mkName sym
    let paramTypes = map S.paramType params

    pushSymTab
    paramOpTypes <- forM params $ \(S.Param p s t) -> do
        checkSymKeyUndef s KeyVar
        addObj s KeyVar $ ObjVal (valBool False)
        opTypeOf t

    returnOpType <- opTypeOf retty
    popSymTab

    addSymKeyDec sym (KeyFunc paramTypes) name (DecExtern paramOpTypes returnOpType False)
    let op = fnOp name paramOpTypes returnOpType False
    addObj sym (KeyFunc paramTypes) (ObjExtern paramTypes retty op)


cmpFuncHdr :: InsCmp CompileState m => S.Stmt -> m ()
cmpFuncHdr (S.Func pos "main" params retty blk) = return ()
cmpFuncHdr (S.Func pos sym params retty blk)    = withPos pos $ do
    let key = KeyFunc (map S.paramType params)
    checkSymKeyUndef sym key
    name <- freshName (mkBSS sym)

    paramOpTypes <- mapM (opTypeOf . S.paramType) params
    returnOpType <- opTypeOf retty
    let op = fnOp name paramOpTypes returnOpType False
    addObj sym key (ObjFunc retty op) 
    

cmpFuncDef :: (MonadFail m, Monad m, MonadIO m) => S.Stmt -> InstrCmpT CompileState m ()
cmpFuncDef (S.Func pos "main" params retty blk) = withPos pos $ do
    assert (params == [])  "main cannot have parameters"
    assert (retty == Void) "main must return void"
    pushSymTab >> mapM_ cmpStmt blk >> popSymTab
cmpFuncDef (S.Func pos sym params retty blk) = withPos pos $ do
    returnOpType <- opTypeOf retty
    paramOpTypes <- mapM (opTypeOf . S.paramType) params
    let paramTypes = map S.paramType params
    let paramNames = map (ParameterName . mkBSS . S.paramName) params
    let paramSyms  = map S.paramName params

    ObjFunc _ op <- look sym (KeyFunc paramTypes)
    let LL.ConstantOperand (C.GlobalReference _ name) = op
    let Name nameStr = name

    addSymKeyDec sym (KeyFunc paramTypes) name (DecFunc paramOpTypes returnOpType)
    addDeclared name

    pushSymTab
    curRetty <- gets curRetType
    modify $ \s -> s { curRetType = retty }
    void $ InstrCmpT . IRBuilderT . lift $ func name (zip paramOpTypes paramNames) returnOpType $ \paramOps -> do
        forM_ (zip3 paramTypes paramOps paramSyms) $ \(typ, op, sym) -> do
            checkSymKeyUndef sym KeyVar
            loc <- valLocal typ
            valStore loc (Val typ op)
            addObj sym KeyVar (ObjVal loc)

        mapM_ cmpStmt blk
        hasTerm <- hasTerminator
        retty <- gets curRetType
        if hasTerm
        then return ()
        else if retty == Void
        then retVoid
        else unreachable

    modify $ \s -> s { curRetType = curRetty }
    popSymTab


cmpStmt :: InsCmp CompileState m => S.Stmt -> m ()
cmpStmt stmt = case stmt of
    S.Print pos exprs -> cmpPrint stmt
    S.Block stmts -> pushSymTab >> mapM_ cmpStmt stmts >> popSymTab

    S.CallStmt pos sym exprs -> withPos pos $ do

        vals <- mapM (valLoad <=< cmpExpr) exprs
        res <- look sym $ KeyFunc (map valType vals)
        op <- case res of
            ObjFunc _ op     -> return op
            ObjExtern _ _ op -> return op

        void $ call op [(o, []) | o <- map valOp vals]

    S.Assign pos pat expr -> withPos pos $ do
        matched <- cmpPattern pat =<< cmpExpr expr
        if_ (valOp matched) (return ()) (void trap) 

    S.Set pos ind expr -> withPos pos $ do
        val <- cmpExpr expr
        case ind of
            S.IndIdent p sym -> do
                ObjVal loc <- look sym KeyVar
                valStore loc val

    S.Return pos Nothing -> withPos pos $ do
        curRetty <- gets curRetType
        assert (curRetty == Void) "must return a value"
        retVoid
        emitBlockStart =<< fresh

    S.Return pos (Just expr) -> withPos pos $ do
        retty <- gets curRetType
        ret . valOp =<< valLoad =<< valAsType retty =<< cmpExpr expr
        emitBlockStart =<< fresh

    S.If pos cnd blk melse -> withPos pos $ do
        pushSymTab
        val <- valLoad =<< cmpCondition cnd

        case melse of
            Nothing                   -> if_ (valOp val) (cmpStmt blk) (return ())
            Just blk2@(S.Block stmts) -> if_ (valOp val) (cmpStmt blk) (cmpStmt blk2)

        popSymTab

    S.While pos cnd blk -> withPos pos $ do
        cond <- freshName "while_cond"
        body <- freshName "while_body"
        exit <- freshName "while_exit"

        br cond
        emitBlockStart cond
        val <- valLoad =<< cmpCondition cnd
        condBr (valOp val) body exit
        
        emitBlockStart body
        pushSymTab
        mapM_ cmpStmt blk
        popSymTab
        br cond
        emitBlockStart exit

    S.Switch pos expr cases -> withPos pos $ do
        val <- cmpExpr expr

        exitName <- freshName "switch_exit"
        trapName <- freshName "switch_trap"
        cndNames <- replicateM (length cases) (freshName "case")
        stmtNames <- replicateM (length cases) (freshName "case_stmt")
        let nextNames = cndNames ++ [trapName]

        br (head nextNames)
        forM_ (zip4 cases cndNames stmtNames (tail nextNames)) $
            \((pat, stmt), cndName, stmtName, nextName) -> do
                emitBlockStart cndName
                pushSymTab
                matched <- valLoad =<< cmpPattern pat val
                condBr (valOp matched) stmtName nextName
                emitBlockStart stmtName
                cmpStmt stmt
                popSymTab
                br exitName

        emitBlockStart trapName
        void trap 
        br exitName
        emitBlockStart exitName

    _ -> error "stmt"


exprIsContextual :: S.Expr -> Bool
exprIsContextual expr = case expr of
    S.Int _ _                              -> True
    S.Tuple _ es | any exprIsContextual es -> True
    S.Null _                               -> True
    S.Table _ ess | any null ess           -> True
    _                                      -> False


-- must return Val unless local variable
cmpExpr :: InsCmp CompileState m =>  S.Expr -> m Value
cmpExpr expr = case expr of
    e | exprIsContextual e     -> return (Exp expr)
    S.Bool pos b               -> return (valBool b)
    S.Char pos c               -> return (valChar c)
    S.Conv pos typ []          -> zeroOf typ
    S.Conv pos typ [S.Null p]  -> withPos pos (adtNull typ)
    S.Conv pos typ exprs       -> withPos pos $ valConstruct typ =<< mapM cmpExpr exprs
    S.Ident pos sym            -> withPos pos $ look sym KeyVar >>= \(ObjVal loc) -> return loc
    S.Infix pos op exprA exprB -> withPos pos $ join $ liftM2 (valsInfix op) (cmpExpr exprA) (cmpExpr exprB)
    S.Prefix pos S.Not   expr  -> withPos pos $ valNot =<< cmpExpr expr
    S.Prefix pos S.Minus expr  -> withPos pos $ valsInfix S.Minus (Exp (S.Int undefined 0)) =<< cmpExpr expr
    S.Append pos exprA exprB   -> withPos pos $ valLoad =<< join (liftM2 tableAppend (cmpExpr exprA) (cmpExpr exprB))
            
    S.String pos s -> do
        loc <- globalStringPtr s =<< fresh
        let pi8 = C.BitCast loc (LL.ptr LL.i8)
        let i64 = toCons $ int64 $ fromIntegral (length s)
        let stc = struct Nothing False [i64, i64, pi8]
        return $ Val (Table [Char]) stc

    S.Call pos sym exprs -> withPos pos $ do
        vals <- mapM cmpExpr exprs
        res <- look sym $ KeyFunc (map valType vals)
        case res of
            ObjConstructor typ   -> valConstruct typ vals
            ObjPtrFieldCons  typ -> adtConstructField sym typ vals
            _                    -> do
                (op, typ) <- case res of
                    ObjFunc Void _     -> err "cannot use void function as expression"
                    ObjExtern _ Void _ -> err "cannot use void function as expression"
                    ObjFunc typ op     -> return (op, typ)
                    ObjExtern _ typ op -> return (op, typ)

                vals' <- mapM valLoad vals
                Val typ <$> call op [(o, []) | o <- map valOp vals']


    S.Len pos expr -> withPos pos $ valLoad =<< do
        val <- cmpExpr expr
        typ <- baseTypeOf (valType val)
        case typ of
            Table _ -> tableLen val
            _       -> err ("cannot take length of type " ++ show typ)

    S.Tuple pos [expr] -> withPos pos (cmpExpr expr)
    S.Tuple pos exprs -> withPos pos $ do
        vals <- mapM cmpExpr exprs
        tup <- valLocal $ Tuple (map valType vals)
        zipWithM_ (valTupleSet tup) [0..] vals
        valLoad tup

    S.Subscript pos aggExpr idxExpr -> withPos pos $ valLoad =<< do
        agg <- cmpExpr aggExpr
        idx <- cmpExpr idxExpr

        idxType <- baseTypeOf (valType idx)
        aggType <- baseTypeOf (valType agg)

        assert (isInt idxType) "index type isn't an integer"

        case aggType of
            Table [t] -> (flip valTupleIdx) 0 =<< tableGetElem agg idx

    S.Range pos expr mstart mend -> withPos pos $ do
        val <- cmpExpr expr
        base <- baseTypeOf (valType val)
        case base of
            Table ts -> do
                start <- maybe (return (valI64 0)) cmpExpr mstart
                valLoad =<< tableRange val start =<< maybe (tableLen val) cmpExpr mend
    
    S.Table pos exprss -> withPos pos $ valLoad =<< do
        valss <- mapM (mapM cmpExpr) exprss
        let rowLen = length (head valss)

        rowTypes <- forM valss $ \vals -> do
            assert (length vals == rowLen) $ "mismatched table row length of " ++ show (length vals)
            let typ = valType (head vals)
            mapM_ (checkTypesMatch typ) (map valType vals)
            return typ

        rows <- forM (zip rowTypes [0..]) $ \(t, r) -> do
            mal <- valMalloc t (valI64 rowLen)
            forM_ [0..rowLen - 1] $ \i -> do
                ptr <- valPtrIdx mal (valI64 i) 
                valStore ptr ((valss !! r) !! i)
            return mal

        tab <- valLocal (Table rowTypes)
        tableSetLen tab (valI64 rowLen)
        tableSetCap tab (valI64 rowLen)
        zipWithM_ (tableSetRow tab) [0..] rows
        return tab

    _ -> err "invalid expression"


cmpCondition :: InsCmp CompileState m => S.Condition -> m Value
cmpCondition cnd = do
    val <- case cnd of
        S.CondExpr expr -> cmpExpr expr
        S.CondMatch pat expr -> cmpPattern pat =<< cmpExpr expr

    assertBaseType (== Bool) (valType val)
    return val



cmpPattern :: InsCmp CompileState m => S.Pattern -> Value -> m Value
cmpPattern pat val = case pat of
    S.PatIgnore pos -> return (valBool True)

    S.PatLiteral (S.Null pos) -> withPos pos $ do
        ADT ts <- assertBaseType isADT (valType val)
        let ns = filter ((== Void) . unNamed) ts
        assert (length ns == 1) "adt type does not support a unique null value"
        en <- adtEnum val
        valsInfix S.EqEq en $ valI64 $ fromJust $ elemIndex (head ns) ts

    S.PatLiteral expr -> valsInfix S.EqEq val =<< cmpExpr expr

    S.PatGuarded pos pat expr -> withPos pos $ do
        match <- cmpPattern pat =<< valLoad val
        guard <- valLoad =<< cmpExpr expr
        assertBaseType (== Bool) (valType guard)
        valsInfix S.AndAnd match guard

    S.PatIdent pos sym -> withPos pos $ do
        checkSymKeyUndef sym KeyVar
        loc <- valLocal (valType val)
        valStore loc val
        addObj sym KeyVar (ObjVal loc)
        return (valBool True)

    S.PatTuple pos pats -> withPos pos $ do
        Tuple ts <- assertBaseType isTuple (valType val)
        assert (length ts == length pats) "tuple pattern length mismatch"
        bs <- forM (zip pats [0..]) $ \(p, i) ->
            cmpPattern p =<< valTupleIdx val i

        foldM (valsInfix S.AndAnd) (valBool True) bs

    S.PatArray pos pats -> withPos pos $ do
        base <- baseTypeOf (valType val)
        case base of
            Table ts -> do
                len   <- tableLen val
                lenEq <- valsInfix S.EqEq len (valI64 $ length pats)

                assert (length ts == 1) "patterns don't support multiple rows (yet)"
                bs <- forM (zip pats [0..]) $ \(p, i) -> do
                    tup <- tableGetElem val (valI64 i)
                    cmpPattern p =<< valTupleIdx tup 0

                foldM (valsInfix S.AndAnd) (valBool True) (lenEq:bs)
            _ -> error (show base)

    S.PatSplit pos pat@(S.PatArray p pats) rest -> withPos pos $ do
        initMatched <- cmpPattern pat =<< tableRange val (valI64 0) (valI64 $ length pats)
        restMatched <- cmpPattern rest =<< tableRange val (valI64 $ length pats) =<< tableLen val
        valsInfix S.AndAnd initMatched restMatched

    S.PatSplit pos (S.PatLiteral (S.String p s)) rest -> withPos pos $ do
        let charPats = map (S.PatLiteral . S.Char p) s
        let arrPat   = S.PatArray p charPats
        cmpPattern (S.PatSplit pos arrPat rest) val

    S.PatTyped pos typ pat -> withPos pos $ do
        ADT ts <- assertBaseType isADT (valType val)

        ns <- fmap catMaybes $ forM ts $ \t -> case t of
            Named n t -> case typ of
                Typedef s -> return (if s == n then Just (Named n t) else Nothing)
                _         -> return Nothing
            t -> return (if t == typ then Just t else Nothing)


        assert (length ns == 1) "invalid field name"
        let t = head ns

        en <- adtEnum val
        b <- valsInfix S.EqEq en $ valI64 $ fromJust (elemIndex t ts)

        loc <- valLocal (ADT [unNamed t])
        adtSetPi8 loc =<< adtPi8 val
        val <- adtDeref loc

        valsInfix S.AndAnd b =<< cmpPattern pat val
    
    _ -> error (show pat)



cmpPrint :: InsCmp CompileState m => S.Stmt -> m ()
cmpPrint (S.Print pos exprs) = withPos pos $ do
    prints =<< mapM cmpExpr exprs
    where
        prints :: InsCmp CompileState m => [Value] -> m ()
        prints []     = void $ printf "\n" []
        prints [val]  = valPrint "\n" val
        prints (v:vs) = valPrint ", " v >> prints vs


valConstruct :: InsCmp CompileState m => Type -> [Value] -> m Value
valConstruct typ []                         = zeroOf typ
valConstruct typ [val] | typ == valType val = valLoad val
valConstruct typ [val']                      = do
    val <- valLoad val'
    base <- baseTypeOf typ
    case base of
        I32 -> case val of
            Val I64 op -> Val base <$> trunc op LL.i32
            Val I8 op  -> Val base <$> sext op LL.i32

        I64 -> case val of
            Val Char op -> Val base <$> sext op LL.i64

        Char -> case val of
            Val I64 op -> Val base <$> trunc op LL.i8
            Val I32 op -> Val base <$> trunc op LL.i8
            _          -> error (show val)

        ADT _   -> adtConstruct typ val
        _           -> do
            pureType    <- pureTypeOf typ
            pureValType <- pureTypeOf (valType val)
            checkTypesMatch pureType pureValType
            Val typ <$> valOp <$> valLoad val


valAsType :: InsCmp CompileState m => Type -> Value -> m Value
valAsType typ val = case val of
    Val _ _       -> checkTypesMatch typ (valType val) >> return val
    Ptr _ _       -> checkTypesMatch typ (valType val) >> return val
    Exp (S.Null _)-> adtNull typ
    Exp (S.Table _ [[]]) -> do
        Table ts <- assertBaseType isTable typ
        zeroOf typ
    Exp (S.Tuple _ es) -> do
        Tuple ts <- assertBaseType isTuple typ

        assert (length es == length ts) ("does not satisfy " ++ show typ)
        vals <- forM (zip ts es) $ \(t, e) ->
            valAsType t =<< cmpExpr e 

        tup <- valLocal typ
        zipWithM_ (valTupleSet tup) [0..] =<< zipWithM valAsType ts vals
        return tup
