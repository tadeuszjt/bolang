module CmpADT where

import Data.Word
import Control.Monad

import LLVM.AST.Type
import LLVM.IRBuilder.Instruction

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
            | x < 2^8  -> return I64
            | x < 2^16 -> return I32
            | x < 2^32 -> return I32
            | x < 2^64 -> return I64
    
    enumOpTyp <- opTypeOf enumTyp
    enumSize <- sizeOf enumOpTyp


    memTyps <- forM datas $ \dat -> case dat of
        S.DataIdent p sym       -> return (Tuple [enumTyp])
        S.DataFunc p sym params -> return $ Tuple (enumTyp : map (fromASTType . S.paramType) params)

    memSizes <- mapM sizeOf =<< mapM opTypeOf memTyps
    let memMaxSize = maximum memSizes

    fillTyp <- case memMaxSize of
        x
            | mod x 8 == 0 -> return $ Array (div x 8) I64
            | mod x 4 == 0 -> return $ Array (div x 4) I32
            | otherwise     -> return $ Array x I8

    let dataConcTyp = fillTyp

    forM_ (zip3 memTyps datas [0..]) $ \(typ, dat, i) -> do
        checkUndefined (S.dataSymbol dat)
        case dat of
            S.DataIdent p sym -> withPos p $ do
                addSymObj sym (KeyFunc []) $ ObjInline $ \[] -> do
                    Ptr _ loc <- valLocal dataConcTyp
                    ptr <- bitcast loc (ptr enumOpTyp)
                    valStore (Ptr enumTyp ptr) (consInt enumTyp i)
                    return (Ptr dataTyp loc)

            S.DataFunc p sym params -> withPos p $ do
                let paramSymbols = map S.paramName params
                let paramTypes   = map (fromASTType . S.paramType) params
                pushSymTab
                forM_ paramSymbols $ \sym -> checkUndefined sym
                popSymTab
                addSymObj sym (KeyFunc paramTypes) $ ObjInline $ \args -> do
                    Ptr _ loc <- valLocal dataConcTyp
                    ptr1 <- bitcast loc (ptr enumOpTyp) 
                    valStore (Ptr enumTyp ptr1) (consInt enumTyp i)

                    opTyp <- opTypeOf typ
                    ptr2 <- bitcast loc (ptr opTyp)
                    let val = Ptr typ ptr2
                    forM_ (zip args [0..]) $ \(arg, ai) ->
                        valTupleSet val (ai + 1) arg

                    return (Ptr dataTyp loc)


    addSymObj symbol KeyType $ ObjData 
        { dataConcTyp = dataConcTyp
        , dataPrintFn = (\v -> printFn enumTyp memTyps v)
        }

    where

        printFn :: ValType -> [ValType] -> Value -> Instr ()
        printFn enumTyp memTyps val@(Ptr _ loc) = do
            let memSymbols = map S.dataSymbol datas
            enumOpTyp <- opTypeOf enumTyp
            enPtr <- bitcast loc (ptr enumOpTyp)
            en <- valLoad (Ptr enumTyp enPtr)

            casesM <- forM (zip3 memSymbols memTyps [0..]) $ \(sym, typ, i) -> do
                let cmpCnd = do
                    Val Bool cnd <- valsEqual en $ consInt (valType en) i
                    return cnd

                let cmpStmt = do
                    printf sym []
                    opTyp <- opTypeOf typ
                    ptr2 <- bitcast loc (ptr opTyp)
                    valPrint "" (Ptr typ ptr2)

                return (cmpCnd, cmpStmt)

            switch_ casesM
