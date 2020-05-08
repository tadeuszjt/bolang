{-# LANGUAGE ForeignFunctionInterface #-}

module Main where

import           Control.Monad
import           Control.Monad.IO.Class
import           System.Console.Haskeline
import           System.Environment
import           System.IO
import qualified Data.ByteString.Char8    as BS
import qualified Data.Set                 as Set
import qualified Data.Map                 as Map

import           LLVM.AST
import           LLVM.Context
import qualified LLVM.Module              as M
import           LLVM.PassManager

import qualified Compiler                 as C
import qualified CmpVal                   as C
import qualified Cmp                      as C
import qualified Lexer                    as L
import qualified Parser                   as P
import           JIT


main :: IO ()
main = do
    args <- getArgs
    let verbose = "-v" `elem` args
    let optimise = not ("-n" `elem` args)
    let hasFile  = length args > 0 && head (head args) /= '-'

    if not hasFile then
        withSession optimise $ \session -> repl session verbose
	else
        let filename = head args in
        withFile filename ReadMode $ \h ->
            withContext $ \ctx ->
                withPassManager defaultCuratedPassSetSpec $ \pm -> do
                    content <- hGetContents h
                    case compile C.initCmpState content verbose of
                        Left err -> printError err content
                        Right (defs, state) -> do
                            forM_ (head $ C.symTab state) $ \ent -> do
                                forM_ ent $ \e ->
                                    putStrLn (show e)
                                putStrLn ""
                            let astmod = defaultModule { moduleDefinitions = defs }
                            M.withModuleFromAST ctx astmod $ \mod -> do
                                when optimise $ do
                                    passRes <- runPassManager pm mod
                                    when verbose $ putStrLn ("optimisation pass: " ++ if passRes then "success" else "fail")
                                when verbose (BS.putStrLn =<< M.moduleLLVMAssembly mod)
                                M.writeLLVMAssemblyToFile (M.File $ filename ++ ".ll") mod


repl :: Session -> Bool -> IO ()
repl session verbose = runInputT defaultSettings (loop C.initCmpState)
    where
        loop :: C.MyCmpState -> InputT IO ()
        loop state = do
            getInputLine "% " >>= \minput -> case minput of
                Nothing    -> return ()
                Just "q"   -> return ()
                Just ""    -> loop state
                Just input -> do
                    when verbose $ liftIO (putStrLn "compiling...")
                    case compile state input verbose of
                        Left err             -> do
                            liftIO $ printError err input 
                            loop state
                        Right (defs, state') -> do
                            let keepModule = not $ Set.null (C.exported state')
                            let verbose    = True
                            liftIO (jitAndRun defs session keepModule verbose)
                            loop state'
                                { C.exported = Set.empty
                                , C.declared = Set.empty
                                }


compile :: C.MyCmpState -> String -> Bool -> Either C.CmpError ([Definition], C.MyCmpState)
compile state source verbose =
    case L.alexScanner source of
        Left  errStr -> Left $ C.CmpError (C.TextPos{}, errStr)
        Right tokens -> case (P.parseTokens tokens) 0 of
            P.ParseOk ast -> C.compile state ast


printError :: C.CmpError -> String -> IO ()
printError (C.CmpError (C.TextPos p l c, str)) source = do
    putStrLn ("error " ++ show l ++ ":" ++ show c ++ " " ++ str ++ ":")
    let sourceLines = lines source
    unless (length sourceLines <= 1) $ putStrLn (sourceLines !! (l-2))
    unless (length sourceLines <= 0) $ putStrLn (sourceLines !! (l-1))
    putStrLn (replicate (c-1) '-' ++ "^")
