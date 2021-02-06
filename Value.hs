{-# LANGUAGE FlexibleContexts #-}
module Value where

import Prelude hiding (or, and)
import Data.Word
import Data.Maybe
import Data.List hiding (or, and)
import Control.Monad
import Control.Monad.State hiding (void)
import Control.Monad.Trans

import qualified LLVM.AST as LL
import qualified LLVM.AST.Type as LL
import LLVM.Internal.EncodeAST
import LLVM.Internal.Coding hiding (alloca)
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Instruction
import qualified LLVM.Internal.FFI.DataLayout as FFI
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as P

import qualified AST as S
import Monad
import CompileState
import Funcs
import Type


assertBaseType :: InsCmp CompileState m => (Type -> Bool) -> Type -> m Type
assertBaseType f typ = do
    base <- baseTypeOf typ
    assert (f base) ("invalid type of " ++ show typ)
    return base


valInt :: Integral i => Type -> i -> Value
valInt I8 n  = Val I8  $ int8  (fromIntegral n)
valInt I32 n = Val I32 $ int32 (fromIntegral n)
valInt I64 n = Val I64 $ int64 (fromIntegral n)


valI64 :: Integral i => i -> Value
valI64 = valInt I64 


valChar :: Char -> Value
valChar c = Val Char (int8 $ fromIntegral $ fromEnum c)


valBool :: Bool -> Value
valBool b = Val Bool (if b then bit 1 else bit 0)


valLoad :: InsCmp s m => Value -> m Value
valLoad (Val typ op)  = return (Val typ op)
valLoad (Ptr typ loc) = fmap (Val typ) (load loc 0)
valLoad (CtxInt n)    = return (valI64 n)


valStore :: InsCmp CompileState m => Value -> Value -> m ()
valStore (Ptr typ loc) val = do
    checkTypesMatch typ (valType val)
    case val of
        Ptr t l  -> store loc 0 =<< load l 0
        Val t o  -> store loc 0 o
        CtxInt n -> valStore (Ptr typ loc) =<< valLoad val


valLocal :: InsCmp CompileState m => Type -> m Value
valLocal typ = do
    opTyp <- opTypeOf typ
    loc <- alloca opTyp Nothing 0
    return (Ptr typ loc)
    

valMalloc :: InsCmp CompileState m => Type -> Value -> m Value
valMalloc typ len = do
    size <- fmap (valInt I64) (sizeOf typ)
    num  <- valsInfix S.Times len size
    pi8  <- malloc (valOp num)
    opTyp <- opTypeOf typ
    fmap (Ptr typ) $ bitcast pi8 (LL.ptr opTyp)


valsInfix :: InsCmp CompileState m => S.Op -> Value -> Value -> m Value
valsInfix operator (CtxInt a) (CtxInt b) = return $ case operator of
    S.Plus   -> CtxInt (a + b)
    S.Minus  -> CtxInt (a - b)
    S.Times  -> CtxInt (a * b)
    S.Divide -> CtxInt (a `div` b)
    S.GT     -> valBool (a > b)
    S.LT     -> valBool (a < b)
valsInfix operator (CtxInt a) b = do
    typ <- assertBaseType isInt (valType b)
    valsInfix operator (valInt typ a) b
valsInfix operator a (CtxInt b) = do
    typ <- assertBaseType isInt (valType a)
    valsInfix operator a (valInt typ b)
valsInfix operator a b = do
    baseA <- baseTypeOf (valType a)
    baseB <- baseTypeOf (valType b)
    checkTypesMatch baseA baseB

    Val _ opA <- valLoad a
    Val _ opB <- valLoad b
    valsInfix' operator (valType a) baseA opA opB
    where
        valsInfix' :: InsCmp CompileState m => S.Op -> Type -> Type -> LL.Operand -> LL.Operand -> m Value
        valsInfix' operator typ base opA opB
            | isInt base || base == Char = case operator of
                S.Plus   -> fmap (Val typ) (add opA opB)
                S.Minus  -> fmap (Val typ) (sub opA opB)
                S.Times  -> fmap (Val typ) (mul opA opB)
                S.Divide -> fmap (Val typ) (sdiv opA opB)
                S.GT     -> fmap (Val Bool) (icmp P.SGT opA opB)
                S.LT     -> fmap (Val Bool) (icmp P.SLT opA opB)
                S.GTEq   -> fmap (Val Bool) (icmp P.SGE opA opB)
                S.LTEq   -> fmap (Val Bool) (icmp P.SLE opA opB)
                S.EqEq   -> fmap (Val Bool) (icmp P.EQ opA opB)
                S.NotEq  -> fmap (Val Bool) (icmp P.NE opA opB)
                _        -> error ("int infix: " ++ show operator)
            | typ == Bool = case operator of
                S.OrOr   -> fmap (Val Bool) (or opA opB)
                S.AndAnd -> fmap (Val Bool) (and opA opB)
                _        -> error ("bool infix: " ++ show operator)
            | otherwise  = err ("cannot use op: " ++ show operator ++ " for: " ++ show typ)
        

valNot :: InsCmp CompileState m => Value -> m Value
valNot val = do
    assertBaseType (== Bool) (valType val)
    op <- fmap valOp (valLoad val)
    fmap (Val (valType val)) $ icmp P.EQ op (bit 0)


valPtrIdx :: InsCmp s m => Value -> Value -> m Value
valPtrIdx (Ptr typ loc) idx = do
    Val I64 i <- valLoad idx
    fmap (Ptr typ) (gep loc [i])


valTupleSet :: InsCmp CompileState m => Value -> Word -> Value -> m Value
valTupleSet tup i val = do
    Tuple ts <- assertBaseType isTuple (valType tup)

    assert (fromIntegral i < length ts) "invalid tuple index"
    case tup of
        Ptr _ _ -> do
            ptr <- valTupleIdx tup i
            valStore ptr val
            return tup

        Val _ _ -> do
            val' <- valLoad val
            fmap (Val $ valType tup) $ insertValue (valOp tup) (valOp val') [fromIntegral i]


valTupleIdx :: InsCmp CompileState m => Value -> Word -> m Value
valTupleIdx tup i = do
    Tuple ts <- assertBaseType isTuple (valType tup)

    let t = ts !! fromIntegral i
    case tup of
        Ptr _ loc -> fmap (Ptr t) $ gep loc [int32 0, int32 $ fromIntegral i]
        Val _ op  -> fmap (Val t) $ extractValue op [fromIntegral i]


valArrayIdx :: InsCmp CompileState m => Value -> Value -> m Value
valArrayIdx (Ptr (Array n t) loc) idx = do
    Val idxTyp idx <- valLoad idx
    assert (isInt idxTyp) "array index isn't an integer"
    fmap (Ptr t) $ gep loc [int64 0, idx]


valArrayConstIdx :: InsCmp CompileState m => Value -> Word -> m Value
valArrayConstIdx val i = do
    Array n t <- assertBaseType isArray (valType val)
    case val of
        Ptr typ loc -> fmap (Ptr t) $ gep loc [int64 0, int64 (fromIntegral i)]
        Val typ op  -> fmap (Val t) $ extractValue op [fromIntegral i]


valMemCpy :: InsCmp CompileState m => Value -> Value -> Value -> m ()
valMemCpy (Ptr dstTyp dst) (Ptr srcTyp src) len = do
    checkTypesMatch dstTyp srcTyp
    size <- fmap valI64 (sizeOf dstTyp)
    num <- valsInfix S.Times len size
    pDstI8 <- bitcast dst (LL.ptr LL.i8)
    pSrcI8 <- bitcast src (LL.ptr LL.i8)
    void $ memcpy pDstI8 pSrcI8 (valOp num)



valContextual :: Value -> Bool
valContextual (CtxTable _) = True
valContextual (CtxTuple _) = True
valContextual (Null)       = True
valContextual _            = False


checkTypesMatch :: BoM CompileState m => Type -> Type -> m ()
checkTypesMatch typA typB
    | isSimple typA  = assert (typA == typB) str
    | isTable typA   = assert (typA == typB) str
    | isTuple typA   = assert (typA == typB) str
    | isTypedef typA = assert (typA == typB) str
    | isPointer typA = assert (typA == typB) str
    | otherwise      = err (show typA ++ " does not match " ++ show typB)
    where
        str = show typA ++ " does not match " ++ show typB


baseTypeOf :: ModCmp CompileState m => Type -> m Type
baseTypeOf typ = case typ of
    Typedef s -> do ObType t _ <- look s KeyType; baseTypeOf t
    Named s t -> baseTypeOf t
    _         -> return typ


pureTypeOf :: ModCmp CompileState m => Type -> m Type
pureTypeOf typ = case typ of
    Void       -> return Void
    Typedef s  -> do ObType t _ <- look s KeyType; pureTypeOf t
    Table ts   -> fmap Table (mapM pureTypeOf ts)
    Tuple ts   -> fmap Tuple (mapM pureTypeOf ts)
    Array n t  -> fmap (Array n) (pureTypeOf t)
    Pointer ts -> fmap Pointer (mapM pureTypeOf ts)
    Named n t  -> pureTypeOf t
    _ | isSimple typ -> return typ
    _ -> error (show typ)




zeroOf :: ModCmp CompileState m => Type -> m Value
zeroOf typ = case typ of
    _ | isInt typ -> return (valInt typ 0)
    Bool          -> return (valBool False)
    Char          -> return (valChar '\0')
    Tuple ts      -> do
        ops <- fmap (map toCons) $ fmap (map valOp) (mapM zeroOf ts)
        return $ Val typ (struct Nothing False ops)

    Table ts      -> do
        let zi64 = toCons (int64 0)
        ptrs <- fmap (map LL.ptr) (mapM opTypeOf ts)
        let zptrs = map (C.IntToPtr zi64) ptrs
        return . (Val typ) $ struct Nothing False (zi64:zi64:zptrs)

    Array n t     -> 
        fmap (Val typ . array) $ replicateM (fromIntegral n) $ fmap (toCons . valOp) (zeroOf t)

    Pointer [t] -> do
        pt <- fmap LL.ptr (opTypeOf t)
        return $ Val typ $ cons (C.Null pt)

    Typedef sym   -> do
        Val t op <- zeroOf =<< baseTypeOf typ
        return (Val typ op)

    _             -> fail ("no zero val for: " ++ show typ)


opTypeOf :: ModCmp CompileState m => Type -> m LL.Type
opTypeOf typ = case typ of
    Void      -> return LL.VoidType
    I16       -> return LL.i16
    I32       -> return LL.i32
    I64       -> return LL.i64
    Char      -> return LL.i8
    Bool      -> return LL.i1
    Tuple ts  -> fmap (LL.StructureType False) (mapM opTypeOf ts)
    Array n t -> fmap (LL.ArrayType $ fromIntegral n) (opTypeOf t)
    Named n t -> opTypeOf t

    Table ts  -> do
        ptrOpTypes <- mapM (fmap LL.ptr . opTypeOf) ts
        return $ LL.StructureType False (LL.i64:LL.i64:ptrOpTypes)

    Pointer []  -> error ""
    Pointer [t] -> return (LL.ptr LL.i8)
    Pointer ts  -> return $ LL.StructureType False [LL.i64, LL.ptr LL.i8]

    Typedef s -> do
        ObType t namem <- look s KeyType
        maybe (opTypeOf t) (return . LL.NamedTypeReference) namem


    _ -> error (show typ) 

sizeOf :: InsCmp CompileState m => Type -> m Word64
sizeOf typ = size =<< opTypeOf =<< pureTypeOf typ
    where
        size :: InsCmp CompileState m => LL.Type -> m Word64
        size typ = do
            ctx <- gets context
            dl <- gets dataLayout
            ptrTyp <- liftIO $ runEncodeAST ctx (encodeM typ)
            liftIO (FFI.getTypeAllocSize dl ptrTyp)

