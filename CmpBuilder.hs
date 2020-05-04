{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module CmpBuilder where

import           Control.Monad
import           Data.Char
import           Prelude                    hiding (EQ, and, or)

import           LLVM.AST 
import           LLVM.AST.IntegerPredicate
import           LLVM.AST.Type              hiding (void)
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Monad
import           LLVM.IRBuilder.Module
import qualified LLVM.AST.Global   as G
import qualified LLVM.AST.Constant as C

import           Cmp


--func :: MonadInstrCmp t m => Name -> [(Type, ParameterName)] -> Type -> ([Operand] -> m ()) -> m ()
--func name params retty instr = do
--    let paramtys = map fst params
--    return ()


for :: MonadInstrCmp t m => Operand -> (Operand -> m ()) -> m ()
for num f = do
    forCond <- freshName "for_cond"
    forBody <- freshName "for_body"
    forExit <- fresh

    i <- alloca i64 Nothing 0
    store i 0 (int64 0)
    br forCond

    emitBlockStart forCond
    li <- load i 0
    cnd <- icmp SLT li num 
    condBr cnd forBody forExit

    emitBlockStart forBody
    store i 0 =<< add li (int64 1)
    f li
    br forCond

    void (emitBlockStart forExit)


putchar :: MonadInstrCmp t m => Char -> m Operand
putchar ch = do
    op <- ensureExtern "putchar" [i32] i32 False
    let c8 = fromIntegral (ord ch)
    call op [(int32 c8, [])]


putchar' :: MonadInstrCmp t m => Operand -> m Operand
putchar' ch = do
    op <- ensureExtern "putchar" [i32] i32 False
    call op [(ch, [])]
    


printf :: MonadInstrCmp t m => String -> [Operand] -> m Operand
printf fmt args = do
    op <- ensureExtern "printf" [ptr i8] i32 True
    str <- globalStringPtr fmt =<< fresh
    call op $ map (\a -> (a, [])) (cons str:args)


puts :: MonadInstrCmp t m => Operand -> m Operand
puts str = do
    op <- ensureExtern "puts" [ptr i8] i32 False
    call op [(str, [])]


strcmp :: MonadInstrCmp t m => Operand -> Operand -> m Operand
strcmp a b = do
    op <- ensureExtern "strcmp" [ptr i8, ptr i8] i32 False
    call op [(a, []), (b, [])] 


isCons :: Operand -> Bool
isCons (ConstantOperand _) = True
isCons _                   = False


isLocal :: Operand -> Bool
isLocal (LocalReference _ _) = True
isLocal _                    = False


isGlobal :: Operand -> Bool
isGlobal (ConstantOperand (C.GlobalReference _ _)) = True
isGlobal _                                         = False


isPtr :: Operand -> Bool
isPtr (ConstantOperand (C.GlobalReference (PointerType _ _) _)) = True
isPtr (LocalReference  (PointerType _ _) _)                     = True
isPtr _                                                         = False


toCons :: Operand -> C.Constant
toCons (ConstantOperand c) = c


cons :: C.Constant -> Operand
cons = ConstantOperand


globalDef :: Name -> Type -> Maybe C.Constant -> Definition
globalDef nm ty init = GlobalDefinition globalVariableDefaults
    { G.name        = nm
    , G.type'       = ty
    , G.initializer = init
    }


funcDef :: Name -> [(Type, Name)] -> Type -> [BasicBlock] -> Definition
funcDef nm params retty blocks = GlobalDefinition functionDefaults
    { G.name        = nm
    , G.parameters  = ([Parameter t n [] | (t, n) <- params], False)
    , G.returnType  = retty
    , G.basicBlocks = blocks
    }


