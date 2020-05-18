module Print where


import           Control.Monad
import           Control.Monad.State
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Short      as BSS
import           Data.Maybe
import           Data.List                  hiding (and, or)
import           Data.Word
import           Prelude                    hiding (EQ, and, or)

import           LLVM.Context
import           LLVM.AST                   hiding (function, Module)
import qualified LLVM.AST.Constant          as C
import           LLVM.AST.IntegerPredicate
import           LLVM.AST.Type              hiding (void, double)
import           LLVM.Internal.Type
import           LLVM.Internal.EncodeAST
import           LLVM.Internal.Coding           hiding (alloca)
import           Foreign.Ptr
import qualified LLVM.Internal.FFI.DataLayout   as FFI
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad

import qualified AST                        as S
import           Type
import           CmpFuncs
import           CmpMonad
import CmpValue


valPrint :: String -> Value -> Instr ()
valPrint append val = case valType val of
    Annotated s t -> do
        printf (s ++ "=") []
        valPrint append $ val { valType = t }

    Typedef sym -> do
        obj <- look sym KeyType
        case obj of
            ObjData t f -> f val >> void (printf append [])
            ObjType typ -> do
                void $ printf sym []
                t <- nakedTypeOf typ
                if isTuple t then do
                    tup <- nakedTypeOf typ
                    valPrint append $ val { valType = tup }
                else do
                    void $ printf (sym ++ "(") []
                    valPrint (")" ++ append) (val { valType = t })

    Array n t -> do
        putchar '['
        for (int64 $ fromIntegral n-1) $ \i -> do
            valPrint ", " =<< valArrayIdx val (Val I64 i)
        valPrint ("]" ++ append) =<< valArrayConstIdx val (n-1)

    Tuple nm ts -> do
        let len = length ts
        putchar '('
        forM_ [0..len-1] $ \i -> do
            let app = if i < len-1 then ", " else ")" ++ append
            valPrint app =<< valTupleIdx (fromIntegral i) val

    Table nm ts -> do
        printf "{" []
        Val _ op <- valLoad val
        len <- extractValue op [0]
        forM_ (zip ts [0..]) $ \(t, i) -> do
            ot <- opTypeOf t
            pa <- extractValue op [2+i]
            pb <- bitcast pa (ptr ot)
            n <- sub len (int64 1)
            for n $ \j ->
                gep pb [j] >>= \p -> valPrint ", " (Ptr t p)
            p <- gep pb [n]
            valPrint "; " (Ptr t p)

        void $ printf ("}" ++ append) []

    Bool -> do
        Val Bool op <- valLoad val
        str <- globalStringPtr "true\0false" =<< fresh
        idx <- select op (int64 0) (int64 5)
        pst <- gep (cons str) [idx]
        void $ printf ("%s" ++ append) [pst]

    t -> do
        Val _ op <- valLoad val
        void $ case t of
            I8     -> printf ("%d" ++ append) [op]
            I32    -> printf ("%d" ++ append) [op]
            I64    -> printf ("%ld" ++ append) [op]
            F32    -> printf ("%f" ++ append) [op]
            F64    -> printf ("%f" ++ append) [op]
            Char   -> printf ("%c" ++ append) [op]
            String -> printf ("\"%s\"" ++ append) [op]
            t      -> cmpErr ("cannot print value with type: " ++ show t)


