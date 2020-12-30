{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
module Compile where

import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Short      as BSS

import           Data.Maybe
import           Control.Monad.Except       hiding (void)
import           Control.Monad.State        hiding (void)
import           Control.Monad.Trans
import           Control.Monad.Fail         hiding (fail)
import           Control.Monad.Identity     
import qualified Data.Set as Set
import qualified Data.Map as Map
import           LLVM.AST                   hiding (function)
import           LLVM.AST.Global
import           LLVM.AST.Constant          as C
import           LLVM.AST.Type              hiding (void)
import qualified LLVM.AST.Constant          as C
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad

import Monad
import Error
import qualified AST as S
import qualified Type as T
import qualified SymTab
import qualified Flatten as F

mkBSS = BSS.toShort . BS.pack


data CompileState
    = CompileState
        { types   :: Map.Map F.FlatSym Type
        , defs    :: [Definition]
        }
    deriving (Show)

initCompileState
     = CompileState
        { types   = Map.empty
        , defs    = []
        }



compileFlatState
    :: (Monad m, MonadFail m, MonadIO m)
    => Map.Map S.ModuleName CompileState
    -> F.FlattenState
    -> m (Either CmpError CompileState)
compileFlatState importCompiled flatState = do
    res <- runModuleCmpT emptyModuleBuilder initCompileState f
    case res of
        Left err                  -> return (Left err)
        Right (((), defs), state) -> return (Right state { defs = defs })
    where
        f :: (MonadFail m, Monad m, MonadIO m) => ModuleCmpT CompileState m ()
        f = void $ function "main" [] VoidType $ \_ ->
                getInstrCmp cmp

        cmp :: InsCmp CompileState m => m ()
        cmp = do
            forM_ ((Map.! F.KeyType) $ F.flatTab flatState) $ \flat -> do
                let F.ObjType pos typ = (Map.! flat) (F.objTab flatState)
                cmpTypeDef flat pos typ

        cmpTypeDef :: InsCmp CompileState m => F.FlatSym -> TextPos -> T.Type -> m Type
        cmpTypeDef flat pos typ = do
            res <- fmap (Map.lookup flat) (gets types)
            case res of
                Just ty -> return ty
                Nothing -> do
                   name <- freshName (mkBSS flat)
                   ty <- typedef name =<< fmap Just (opTypeOf typ)
                   modify $ \s -> s { types = Map.insert flat ty (types s) }
                   return ty

        opTypeOf :: InsCmp CompileState m => T.Type -> m Type
        opTypeOf typ = case typ of
            T.Void         -> return VoidType
            T.I8           -> return i8
            T.I32          -> return i32
            T.I64          -> return i64
            T.Bool         -> return i1
            T.Char         -> return i32
            T.String       -> return (ptr i8)
            T.Array n t    -> fmap (ArrayType $ fromIntegral n) (opTypeOf t)
            T.Typedef flat -> case Map.lookup flat (F.objTab flatState) of
                    Just (F.ObjType pos t) -> cmpTypeDef flat pos t
                    Nothing                -> do
                        fail (show importCompiled)
                        return $ (Map.! flat) $
                            foldr1 Map.union $ map types (Map.elems importCompiled)
                
            _ -> fail (show typ) 


prettyCompileState :: CompileState -> IO ()
prettyCompileState state = do
    putStrLn "actions:"