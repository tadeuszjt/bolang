{-# LANGUAGE FlexibleContexts #-}
module Value where

import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Short      as BSS

import           Data.Word
import           Data.Maybe
import           Control.Monad.Except       hiding (void)
import           Control.Monad.State        hiding (void)
import           Control.Monad.Trans
import           Control.Monad.Fail         hiding (fail)
import           Control.Monad.Identity     
import qualified Data.Set as Set
import qualified Data.Map as Map

import           LLVM.AST                   hiding (Type, function, Module)
import           LLVM.AST.IntegerPredicate
import           LLVM.AST.Type              hiding (Type, void, double)
import           LLVM.Internal.Type
import           LLVM.Internal.EncodeAST
import           LLVM.Internal.Coding           hiding (alloca)
import           Foreign.Ptr
import qualified LLVM.Internal.FFI.DataLayout   as FFI
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad
import           LLVM.AST.Type              hiding (void)
import qualified LLVM.AST.Constant          as C

import Monad
import CompileState
import Funcs
import qualified JIT
import qualified AST as S
import qualified Type as T


valInt :: T.Type -> Integer -> Value
valInt T.I8 n  = Val T.I8  (int8 n)
valInt T.I32 n = Val T.I32 (int32 n)
valInt T.I64 n = Val T.I64 (int64 n)


valChar :: Char -> Value
valChar c = Val T.Char (int32 $ fromIntegral $ fromEnum c)


valBool :: Bool -> Value
valBool b = Val T.Bool (if b then bit 1 else bit 0)


valLoad :: InsCmp s m => Value -> m Value
valLoad (Val typ op)  = return (Val typ op)
valLoad (Ptr typ loc) = fmap (Val typ) (load loc 0)


valStore :: InsCmp CompileState m => Value -> Value -> m ()
valStore (Ptr typ loc) val = do
    checkTypesMatch typ (valType val)
    case val of
        Ptr t l -> store loc 0 =<< load l 0
        Val t o -> store loc 0 o


valLocal :: InsCmp CompileState m => T.Type -> m Value
valLocal typ = do
    opTyp <- opTypeOf typ
    loc <- alloca opTyp Nothing 0
    --TODO
    --size <- sizeOf typ
    --memset loc (int64 0) $ int64 (fromIntegral size)
    return (Ptr typ loc)
    

valPtrIdx :: InsCmp s m => Value -> Value -> m Value
valPtrIdx (Ptr typ loc) (Val T.I64 i) = fmap (Ptr typ) (gep loc [i])
valPtrIdx (Ptr typ loc) (Ptr T.I64 i) = valPtrIdx (Ptr typ loc) =<< valLoad (Ptr T.I64 i)


valArrayIdx :: InsCmp s m => Value -> Value -> m Value
valArrayIdx (Ptr (T.Array n t) loc) idx = do
    Val idxTyp idx <- valLoad idx
    assert (T.isInt idxTyp) "array index isn't an integer"
    fmap (Ptr t) $ gep loc [int64 0, idx]


valArrayConstIdx :: InsCmp CompileState m => Value -> Word -> m Value
valArrayConstIdx val i = do
    T.Array n t <- baseTypeOf (valType val)
    case val of
        Ptr typ loc -> fmap (Ptr t) $ gep loc [int64 0, int64 (fromIntegral i)]
        Val typ op  -> fmap (Val t) $ extractValue op [fromIntegral i]


valMemCpy :: InsCmp CompileState m => Value -> Value -> Value -> m ()
valMemCpy dst src len = do
    checkTypesMatch (valType dst) (valType src)
    size <- sizeOf (valType dst)
    Val T.I64 l <- valLoad len
    let Ptr _ pDst = dst
    let Ptr _ pSrc = src

    pDstI8 <- bitcast pDst (ptr i8)
    pSrcI8 <- bitcast pSrc (ptr i8)

    num <- mul l (int64 $ fromIntegral size)
    void $ memcpy pDstI8 pSrcI8 num


checkTypesMatch :: BoM s m => T.Type -> T.Type -> m ()
checkTypesMatch typA typB
    | T.isSimple typA = assert (typA == typB) str
    | T.isTable typA  = assert (typA == typB) str
    | otherwise       = error (show typA)
    where
        str = show typA ++ " does not match " ++ show typB


baseTypeOf :: BoM CompileState m => T.Type -> m T.Type
baseTypeOf typ
    | T.isSimple typ = return typ
    | T.isArray typ  = return typ
    | T.isTable typ  = return typ



zeroOf :: ModCmp CompileState m => T.Type -> m Value
zeroOf typ
    | T.isInt typ   = return (valInt typ 0)
    | typ == T.Bool = return (valBool False)
    | typ == T.Char = return (valChar '\0')

    | T.isTable typ = do
        let T.Table ts = typ
        let zi64 = toCons (int64 0)
        ptrs <- fmap (map ptr) (mapM opTypeOf ts)
        let zptrs = map (C.IntToPtr zi64) ptrs
        return . (Val typ) $ struct Nothing False (zi64:zi64:zptrs)

    | T.isArray typ = do
        let T.Array n t = typ
        fmap (Val typ . array) $ replicateM (fromIntegral n) $ fmap (toCons . valOp) (zeroOf t)

    | otherwise     = fail ("no zero val for: " ++ show typ)


sizeOf :: InsCmp CompileState m => T.Type -> m Word64
sizeOf typ = size =<< opTypeOf =<< baseTypeOf typ
    where
        size :: InsCmp CompileState m => Type -> m Word64
        size typ = do
            ctx <- gets context
            dl <- gets dataLayout
            ptrTyp <- liftIO $ runEncodeAST ctx (encodeM typ)
            liftIO (FFI.getTypeAllocSize dl ptrTyp)

opTypeOf :: ModCmp CompileState m => T.Type -> m Type
opTypeOf typ = case typ of
    T.I64       -> return i64
    T.Char      -> return i32
    T.I32       -> return i32
    T.I16       -> return i16
    T.Bool      -> return i1
    T.Tuple ts  -> fmap (StructureType False) (mapM opTypeOf ts)
    T.Array n t -> fmap (ArrayType $ fromIntegral n) (opTypeOf t)
    T.Table ts  -> do
        opTypes <- mapM opTypeOf ts
        let ptrTypes = map ptr opTypes
        return $ StructureType False (i64:i64:ptrTypes)
    T.Typedef s -> do
        ObType t nm <- look s KeyType
        case nm of
            Nothing -> opTypeOf t
            Just n  -> return (NamedTypeReference n)

    _ -> error (show typ) 
