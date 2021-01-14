{-# LANGUAGE FlexibleContexts #-}
module Print where

import Control.Monad

import Value
import CompileState
import Monad
import Funcs
import Table
import qualified Type as T
import qualified AST as S

import LLVM.IRBuilder.Instruction
import LLVM.IRBuilder.Constant
import qualified LLVM.AST.IntegerPredicate as P


valPrint :: InsCmp CompileState m => String -> Value -> m ()
valPrint append val = case valType val of
    T.I64 -> do
        Val _ op <- valLoad val
        void $ printf ("%d" ++ append) [op]

    T.Char -> do
        Val _ op <- valLoad val
        void $ printf ("%c" ++ append) [op]

    T.Tuple ts -> do
        printf "(" []
        forM_ (zip ts [0..]) $ \(t, i) -> do
            elem <- valTupleIdx val (fromIntegral i)
            if i < length ts - 1
            then valPrint ", " elem
            else valPrint (")" ++ append) elem


    T.Table ts -> do
        printf "{" []
        let nrows = fromIntegral (length ts)
        len@(Val T.I64 l) <- valLoad =<< valTableLen val
        lenZero <- valsCompare S.LTEq len (valInt T.I64 0)

        let m1 = forM_ [0..nrows-1] $ \i -> do
            row <- valTableRow i val
            n <- sub l (int64 1)
            for n $ \j ->
                valPrint ", " =<< valPtrIdx row (Val T.I64 j)
            let app = if i < nrows-1 then "; " else "}" ++ append
            valPrint app =<< valPtrIdx row (Val T.I64 n)

        let m2 = void (printf "}" [])

        if_ (valOp lenZero) m2 m1 

    T.Array n t -> do
        printf "[" []
        for (int64 $ fromIntegral n-1) $ \i -> do
            valPrint ", " =<< valArrayIdx val (Val T.I64 i)
        valPrint ("]" ++ append) =<< valArrayConstIdx val (n-1)
        
    _ -> error ("print: " ++ show (valType val))
