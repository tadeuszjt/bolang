module CmpADT where

import Data.Word
import Data.Ord
import Data.List
import Control.Monad
import Control.Monad.State

import LLVM.AST.Type
import LLVM.IRBuilder.Instruction
import LLVM.IRBuilder.Constant

import qualified AST as S
import CmpMonad
import CmpValue
import CmpFuncs


cmpDataDef :: S.Stmt -> Instr ()
cmpDataDef (S.Datadef pos symbol datas) = withPos pos $ do
    checkUndefined symbol
    let dataTyp = Typedef symbol

    enumTyp <- case length datas of
        x
            | x < 2^8  -> return I64 -- I8 causes seq fault
            | x < 2^16 -> return I64
            | x < 2^32 -> return I64
            | x < 2^64 -> return I64
    
    memTyps <- forM datas $ \dat -> case dat of
        S.DataIdent p sym       -> return (Tuple [enumTyp])
        S.DataFunc p sym params -> return $ Tuple (enumTyp : map (fromASTType . S.paramType) params)

    memSizes <- mapM sizeOf =<< mapM opTypeOf memTyps
    let (_, dataConcTyp) = maximumBy (comparing fst) (zip memSizes memTyps)

    forM_ (zip3 memTyps datas [0..]) $ \(typ, dat, i) -> do
        checkUndefined (S.dataSymbol dat)
        case dat of
            S.DataIdent p sym -> withPos p $ do
                checkUndefined sym
                addSymObj sym (KeyFunc []) $ ObjInline $ \[] -> do
                    tup@(Ptr _ _) <- valLocal dataConcTyp
                    valTupleSet tup 0 (consInt enumTyp i)
                    return (tup { valType = dataTyp })

            S.DataFunc p sym params -> withPos p $ do
                checkUndefined sym
                let paramSymbols = map S.paramName params
                let paramTypes   = map (fromASTType . S.paramType) params
                pushSymTab
                forM_ paramSymbols $ \s -> checkUndefined s
                popSymTab
                addSymObj sym (KeyFunc paramTypes) $ ObjInline $ \args -> do
                    tup@(Ptr _ _) <- valLocal dataConcTyp
                    valTupleSet tup 0 (consInt enumTyp i)
                    ptr <- valCast typ tup
                    forM_ (zip args [1..]) $ \(arg, i) -> valTupleSet ptr i arg
                    return (tup { valType = dataTyp })


    addSymObj symbol KeyType $ ObjData 
        { dataConcTyp = dataConcTyp
        , dataPrintFn = printFn memTyps
        }

    where
        printFn :: [ValType] -> Value -> Instr ()
        printFn memTyps dat@(Ptr _ _) = do
            let memSymbols = map S.dataSymbol datas
            en <- valLoad =<< valTupleIdx dat 0

            casesM <- forM (zip3 memSymbols memTyps [0..]) $ \(sym, typ, i) -> do
                let cmpCnd = do
                    Val Bool cnd <- valsEqual en $ consInt (valType en) i
                    return cnd

                let cmpStmt = do
                    tup <- valCast typ dat
                    len <- valLen tup
                    printf (sym ++ if len > 1 then "(" else "") []
                    forM_ [1..len-1] $ \i -> do
                        let app = if i < len-1 then ", " else ")"
                        valPrint app =<< valTupleIdx tup (fromIntegral i)

                return (cmpCnd, cmpStmt)

            switch_ casesM
