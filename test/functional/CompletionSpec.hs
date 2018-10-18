{-# LANGUAGE OverloadedStrings #-}
module CompletionSpec where

import Control.Applicative.Combinators
import Control.Monad.IO.Class
import Control.Lens hiding ((.=))
import Data.Aeson
import Language.Haskell.LSP.Test
import Language.Haskell.LSP.Types
import Language.Haskell.LSP.Types.Lens hiding (applyEdit)
import Test.Hspec
import TestUtils

spec :: Spec
spec = describe "completions" $ do
  it "works" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
    doc <- openDoc "Completion.hs" "haskell"
    _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

    let te = TextEdit (Range (Position 5 7) (Position 5 24)) "put"
    _ <- applyEdit doc te

    compls <- getCompletions doc (Position 5 9)
    let item = head $ filter ((== "putStrLn") . (^. label)) compls
    liftIO $ do
      item ^. label `shouldBe` "putStrLn"
      item ^. kind `shouldBe` Just CiFunction
      item ^. detail `shouldBe` Just "String -> IO ()\nPrelude"
      item ^. insertTextFormat `shouldBe` Just Snippet
      item ^. insertText `shouldBe` Just "putStrLn ${1:String}"

  it "completes imports" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
    doc <- openDoc "Completion.hs" "haskell"
    _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

    let te = TextEdit (Range (Position 1 17) (Position 1 26)) "Data.M"
    _ <- applyEdit doc te

    compls <- getCompletions doc (Position 1 22)
    let item = head $ filter ((== "Maybe") . (^. label)) compls
    liftIO $ do
      item ^. label `shouldBe` "Maybe"
      item ^. detail `shouldBe` Just "Data.Maybe"
      item ^. kind `shouldBe` Just CiModule

  it "completes qualified imports" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
    doc <- openDoc "Completion.hs" "haskell"
    _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

    let te = TextEdit (Range (Position 2 17) (Position 1 25)) "Dat"
    _ <- applyEdit doc te

    compls <- getCompletions doc (Position 1 19)
    let item = head $ filter ((== "Data.List") . (^. label)) compls
    liftIO $ do
      item ^. label `shouldBe` "Data.List"
      item ^. detail `shouldBe` Just "Data.List"
      item ^. kind `shouldBe` Just CiModule
 
  it "completes language extensions" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
    doc <- openDoc "Completion.hs" "haskell"
    _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

    let te = TextEdit (Range (Position 0 24) (Position 0 31)) ""
    _ <- applyEdit doc te

    compls <- getCompletions doc (Position 0 24)
    let item = head $ filter ((== "OverloadedStrings") . (^. label)) compls
    liftIO $ do
      item ^. label `shouldBe` "OverloadedStrings"
      item ^. kind `shouldBe` Just CiKeyword   
  
  it "completes with no prefix" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
    doc <- openDoc "Completion.hs" "haskell"
    _ <- skipManyTill loggingNotification (count 2 noDiagnostics)
    compls <- getCompletions doc (Position 5 7)
    liftIO $ filter ((== "!!") . (^. label)) compls `shouldNotSatisfy` null
  
  describe "contexts" $ do
    it "only provides type suggestions" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Context.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)
      compls <- getCompletions doc (Position 2 17)
      liftIO $ do
        compls `shouldContainCompl` "Integer"
        compls `shouldNotContainCompl` "interact"

    it "only provides type suggestions" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Context.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)
      compls <- getCompletions doc (Position 3 9)
      liftIO $ do
        compls `shouldContainCompl` "abs" 
        compls `shouldNotContainCompl` "Applicative"
    
    it "completes qualified type suggestions" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Context.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)
      let te = TextEdit (Range (Position 2 17) (Position 2 17)) " -> Conc."
      _ <- applyEdit doc te
      compls <- getCompletions doc (Position 2 26)
      liftIO $ do
        print compls
        compls `shouldNotContainCompl` "forkOn"
        compls `shouldContainCompl` "MVar"
        compls `shouldContainCompl` "Chan"

  describe "snippets" $ do
    it "work for argumentless constructors" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Completion.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

      let te = TextEdit (Range (Position 5 7) (Position 5 24)) "Nothing"
      _ <- applyEdit doc te

      compls <- getCompletions doc (Position 5 14)
      let item = head $ filter ((== "Nothing") . (^. label)) compls
      liftIO $ do
        item ^. insertTextFormat `shouldBe` Just Snippet
        item ^. insertText `shouldBe` Just "Nothing"

    it "work for polymorphic types" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Completion.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

      let te = TextEdit (Range (Position 5 7) (Position 5 24)) "fold"
      _ <- applyEdit doc te

      compls <- getCompletions doc (Position 5 11)
      let item = head $ filter ((== "foldl") . (^. label)) compls
      liftIO $ do
        item ^. label `shouldBe` "foldl"
        item ^. kind `shouldBe` Just CiFunction
        item ^. insertTextFormat `shouldBe` Just Snippet
        item ^. insertText `shouldBe` Just "foldl ${1:b -> a -> b} ${2:b} ${3:t a}"

    it "work for complex types" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Completion.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

      let te = TextEdit (Range (Position 5 7) (Position 5 24)) "mapM"
      _ <- applyEdit doc te

      compls <- getCompletions doc (Position 5 11)
      let item = head $ filter ((== "mapM") . (^. label)) compls
      liftIO $ do
        item ^. label `shouldBe` "mapM"
        item ^. kind `shouldBe` Just CiFunction
        item ^. insertTextFormat `shouldBe` Just Snippet
        item ^. insertText `shouldBe` Just "mapM ${1:a -> m b} ${2:t a}"

    it "respects lsp configuration" $ runSession hieCommand fullCaps "test/testdata/completion" $ do
      doc <- openDoc "Completion.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

      let config = object ["languageServerHaskell" .= (object ["completionSnippetsOn" .= False])]

      sendNotification WorkspaceDidChangeConfiguration (DidChangeConfigurationParams config)

      checkNoSnippets doc

    it "respects client capabilities" $ runSession hieCommand noSnippetsCaps "test/testdata/completion" $ do
      doc <- openDoc "Completion.hs" "haskell"
      _ <- skipManyTill loggingNotification (count 2 noDiagnostics)

      checkNoSnippets doc
  where
    compls `shouldContainCompl` x  =
      filter ((== x) . (^. label)) compls `shouldNotSatisfy` null
    compls `shouldNotContainCompl` x =
      filter ((== x) . (^. label)) compls `shouldSatisfy` null

    checkNoSnippets doc = do
      let te = TextEdit (Range (Position 5 7) (Position 5 24)) "fold"
      _ <- applyEdit doc te

      compls <- getCompletions doc (Position 5 11)
      let item = head $ filter ((== "foldl") . (^. label)) compls
      liftIO $ do
        item ^. label `shouldBe` "foldl"
        item ^. kind `shouldBe` Just CiFunction
        item ^. insertTextFormat `shouldBe` Just PlainText
        item ^. insertText `shouldBe` Nothing
    noSnippetsCaps = (textDocument . _Just . completion . _Just . completionItem . _Just . snippetSupport ?~ False) fullCaps
