------------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.CFG.Generator
-- Description      : Provides a monadic interface for constructing Crucible
--                    control flow graphs.
-- Copyright        : (c) Galois, Inc 2014
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module provides a monadic interface for constructing control flow
-- graph expressions.  The goal is to make it easy to convert languages
-- into CFGs.
--
-- The CFGs generated by this interface are similar to, but not quite
-- the same as, the CFGs defined in "Lang.Crucible.CFG.Core". The
-- module "Lang.Crucible.CFG.SSAConversion" contains code that
-- converts the CFGs produced by this interface into Core CFGs in SSA
-- form.
------------------------------------------------------------------------
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Lang.Crucible.CFG.Generator
  ( -- * Generator
    Generator
  , getPosition
  , setPosition
  , withPosition
  , readGlobal
  , writeGlobal
  , newRef
  , newEmptyRef
  , readRef
  , writeRef
  , dropRef
  , newReg
  , newUnassignedReg
  , newUnassignedReg'
  , readReg
  , assignReg
  , modifyReg
  , modifyRegM
  , extensionStmt
  , forceEvaluation
  , addPrintStmt
  , call
  , mkAtom
  , recordCFG
  , FunctionDef
  , defineFunction
    -- * Low-level terminal expressions.
  , End
  , newLabel
  , newLambdaLabel
  , newLambdaLabel'
  , newLabelG
  , newLambdaLabelG
  , newLambdaLabelG'
  , defineBlock
  , defineLambdaBlock
  , endCurrentBlock
  , resume
  , resume_
  , branch
    -- * Combinators
  , jump
  , jumpToLambda
  , returnFromFunction
  , reportError
  , whenCond
  , unlessCond
  , assertExpr
  , ifte
  , ifte_
  , ifteM
  , MatchMaybe(..)
  , caseMaybe
  , caseMaybe_
  , fromJustExpr
  , assertedJustExpr
  , while
  -- * Re-exports
  , Ctx.Ctx(..)
  , Position
  , module Lang.Crucible.CFG.Reg
  ) where

import           Control.Lens hiding (Index)
import qualified Control.Monad.Fail as F
import           Control.Monad.State.Strict
import qualified Data.Foldable as Fold
import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableFC
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import           Lang.Crucible.CFG.Core (AnyCFG(..), GlobalVar(..))
import           Lang.Crucible.CFG.Expr(App(..), IsSyntaxExtension)
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.CFG.Reg
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.ProgramLoc
import           Lang.Crucible.Types
import           Lang.Crucible.Utils.MonadST
import           Lang.Crucible.Utils.StateContT

------------------------------------------------------------------------
-- CurrentBlockState

-- | A sequence of statements.
type StmtSeq ext s = Seq (Posd (Stmt ext s))

-- | Information about block being generated in Generator.
data CurrentBlockState ext s
   = CBS { -- | Identifier for current block
           cbsBlockID       :: !(BlockID s)
         , cbsInputValues   :: !(ValueSet s)
         , _cbsStmts        :: !(StmtSeq ext s)
         }

initCurrentBlockState :: ValueSet s -> BlockID s -> CurrentBlockState ext s
initCurrentBlockState inputs block_id =
  CBS { cbsBlockID     = block_id
      , cbsInputValues = inputs
      , _cbsStmts      = Seq.empty
      }

-- | Statements translated so far in this block.
cbsStmts :: Simple Lens (CurrentBlockState ext s) (StmtSeq ext s)
cbsStmts = lens _cbsStmts (\s v -> s { _cbsStmts = v })

------------------------------------------------------------------------
-- GeneratorState

-- | State for translating within a basic block.
data IxGeneratorState ext s (t :: * -> *) ret i
  = GS { _gsBlocks    :: !(Seq (Block ext s ret))
       , _gsNextLabel :: !Int
       , _gsNextValue :: !Int
       , _gsCurrent   :: !i
       , _gsPosition  :: !Position
       , _gsState     :: !(t s)
       , _seenFunctions :: ![AnyCFG ext]
       }

type GeneratorState ext s t ret =
  IxGeneratorState ext s t ret (CurrentBlockState ext s)

-- | List of previously processed blocks.
gsBlocks :: Simple Lens (IxGeneratorState ext s t ret i) (Seq (Block ext s ret))
gsBlocks = lens _gsBlocks (\s v -> s { _gsBlocks = v })

-- | Index of next label.
gsNextLabel :: Simple Lens (IxGeneratorState ext s t ret i) Int
gsNextLabel = lens _gsNextLabel (\s v -> s { _gsNextLabel = v })

-- | Index used for register and atom identifiers.
gsNextValue :: Simple Lens (IxGeneratorState ext s t ret i) Int
gsNextValue = lens _gsNextValue (\s v -> s { _gsNextValue = v })

-- | Information about current block.
gsCurrent :: Lens (IxGeneratorState ext s t ret i) (IxGeneratorState ext s t ret j) i j
gsCurrent = lens _gsCurrent (\s v -> s { _gsCurrent = v })

-- | Current source position.
gsPosition :: Simple Lens (IxGeneratorState ext s t ret i) Position
gsPosition = lens _gsPosition (\s v -> s { _gsPosition = v })

-- | User state for current block. This gets reset between blocks.
gsState :: Simple Lens (IxGeneratorState ext s t ret i) (t s)
gsState = lens _gsState (\s v -> s { _gsState = v })

-- | List of functions seen by current generator.
seenFunctions :: Simple Lens (IxGeneratorState ext s t r i) [AnyCFG ext]
seenFunctions = lens _seenFunctions (\s v -> s { _seenFunctions = v })

------------------------------------------------------------------------

startBlock ::
  BlockID s ->
  IxGeneratorState ext s t ret () ->
  GeneratorState ext s t ret
startBlock l gs =
  gs & gsCurrent .~ initCurrentBlockState Set.empty l

-- | Define the current block by defining the position and final
-- statement.
terminateBlock ::
  IsSyntaxExtension ext =>
  TermStmt s ret ->
  GeneratorState ext s t ret ->
  IxGeneratorState ext s t ret ()
terminateBlock term gs =
  do let p = gs^.gsPosition
     let cbs = gs^.gsCurrent
     -- Define block
     let b = mkBlock (cbsBlockID cbs) (cbsInputValues cbs) (cbs^.cbsStmts) (Posd p term)
     -- Store block
     let gs' = gs & gsCurrent .~ ()
                  & gsBlocks  %~ (Seq.|> b)
     seq b gs'

------------------------------------------------------------------------
-- Generator

-- | A generator is used for constructing a CFG from a sequence of
-- monadic actions.
--
-- It wraps the 'ST' monad to allow clients to create references, and
-- has a phantom type parameter to prevent constructs from different
-- CFGs from being mixed.
--
-- The 'ext' parameter indicates the syntax extension.
-- The 'h' parameter is the parameter for the underlying ST monad.
-- The 's' parameter is the phantom parameter for CFGs.
-- The 't' parameter is the parameterized type that allows user-defined
-- state.  It is reset at each block.
-- The 'ret' parameter is the return type of the CFG.
-- The 'a' parameter is the value returned by the monad.

newtype Generator ext h s t ret a
      = Generator { unGenerator :: StateContT (GeneratorState ext s t ret)
                                              (IxGeneratorState ext s t ret ())
                                              (ST h)
                                              a
                  }
  deriving ( Functor
           , Applicative
           , MonadST h
           )

instance Monad (Generator ext h s t ret) where
  return  = Generator . return
  x >>= f = Generator (unGenerator x >>= unGenerator . f)
  fail msg = Generator $ do
     p <- use gsPosition
     fail $ "at " ++ show p ++ ": " ++ msg

instance F.MonadFail (Generator ext h s t ret) where
  fail = fail

instance MonadState (t s) (Generator ext h s t ret) where
  get = Generator $ use gsState
  put v = Generator $ gsState .= v

-- | Get the current position.
getPosition :: Generator ext h s t ret Position
getPosition = Generator $ use gsPosition

-- | Set the current position.
setPosition :: Position -> Generator ext h s t ret ()
setPosition p = Generator $ gsPosition .= p

-- | Set the current position temporarily, and reset it afterwards.
withPosition :: Position
             -> Generator ext h s t ret a
             -> Generator ext h s t ret a
withPosition p m = do
  old_pos <- getPosition
  setPosition p
  v <- m
  setPosition old_pos
  return v

freshValueIndex :: MonadState (IxGeneratorState ext s t ret i) m => m Int
freshValueIndex = do
  n <- use gsNextValue
  gsNextValue .= n+1
  return n

newUnassignedReg'' :: MonadState (IxGeneratorState ext s r ret i) m => TypeRepr tp -> m (Reg s tp)
newUnassignedReg'' tp = do
  p <- use gsPosition
  n <- freshValueIndex
  return $! Reg { regPosition = p
                , regId = n
                , typeOfReg = tp
                }

addStmt :: MonadState (GeneratorState ext s r ret) m => Stmt ext s -> m ()
addStmt s = do
  p <- use gsPosition
  cbs <- use gsCurrent
  let ps = Posd p s
  seq ps $ do
  let cbs' = cbs & cbsStmts %~ (Seq.|> ps)
  seq cbs' $ gsCurrent .= cbs'

freshAtom :: IsSyntaxExtension ext => AtomValue ext s tp -> Generator ext h s t ret (Atom s tp)
freshAtom av = Generator $ do
  p <- use gsPosition
  i <- freshValueIndex
  let atom = Atom { atomPosition = p
                  , atomId = i
                  , atomSource = Assigned
                  , typeOfAtom = typeOfAtomValue av
                  }
  addStmt $ DefineAtom atom av
  return atom

-- | Create an atom equivalent to the given expression if it is
-- not already an atom.
mkAtom :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Atom s tp)
mkAtom (AtomExpr a)   = return a
mkAtom (App a)        = freshAtom . EvalApp =<< traverseFC mkAtom a

-- | Generate a new virtual register with the given initial value.
newReg :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Reg s tp)
newReg e = do
  a <- mkAtom e
  Generator $ do
    r <- newUnassignedReg'' (typeOfAtom a)
    addStmt (SetReg r a)
    return r

-- | Read a global variable.
readGlobal :: IsSyntaxExtension ext => GlobalVar tp -> Generator ext h s t ret (Expr ext s tp)
readGlobal v = AtomExpr <$> freshAtom (ReadGlobal v)

-- | Write to a global variable.
writeGlobal :: IsSyntaxExtension ext => GlobalVar tp -> Expr ext s tp -> Generator ext h s t ret ()
writeGlobal v e = do
  a <-  mkAtom e
  Generator $ addStmt $ WriteGlobal v a

-- | Read the current value of a reference cell.
readRef :: IsSyntaxExtension ext => Expr ext s (ReferenceType tp) -> Generator ext h s t ret (Expr ext s tp)
readRef ref = do
  r <- mkAtom ref
  AtomExpr <$> freshAtom (ReadRef r)

-- | Write the given value into the reference cell.
writeRef :: IsSyntaxExtension ext => Expr ext s (ReferenceType tp) -> Expr ext s tp -> Generator ext h s t ret ()
writeRef ref val = do
  r <- mkAtom ref
  v <- mkAtom val
  Generator $ addStmt (WriteRef r v)

-- | Deallocate the given reference cell, returning it to an uninialized state.
--   The reference cell can still be used; subsequent writes will succeed,
--   and reads will succeed if some value is written first.
dropRef :: IsSyntaxExtension ext => Expr ext s (ReferenceType tp) -> Generator ext h s t ret ()
dropRef ref = do
  r <- mkAtom ref
  Generator $ addStmt (DropRef r)

-- | Generate a new reference cell with the given initial contents.
newRef :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Expr ext s (ReferenceType tp))
newRef val = do
  v <- mkAtom val
  AtomExpr <$> freshAtom (NewRef v)

-- | Generate a new empty reference cell.  If an unassigned reference is later
--   read, it will generate a runtime error.
newEmptyRef :: IsSyntaxExtension ext => TypeRepr tp -> Generator ext h s t ret (Expr ext s (ReferenceType tp))
newEmptyRef tp =
  AtomExpr <$> freshAtom (NewEmptyRef tp)

-- | Produce a new virtual register without giving it an initial value.
--   NOTE! If you fail to initialize this register with a subsequent
--   call to @assignReg@, errors will arise during SSA conversion.
newUnassignedReg' :: TypeRepr tp -> End ext h s t ret (Reg s tp)
newUnassignedReg' tp = End $ newUnassignedReg'' tp

-- | Produce a new virtual register without giving it an initial value.
--   NOTE! If you fail to initialize this register with a subsequent
--   call to @assignReg@, errors will arise during SSA conversion.
newUnassignedReg :: TypeRepr tp -> Generator ext h s t ret (Reg s tp)
newUnassignedReg tp = Generator $ newUnassignedReg'' tp

-- | Get the current value of a register.
readReg :: IsSyntaxExtension ext => Reg s tp -> Generator ext h s t ret (Expr ext s tp)
readReg r = AtomExpr <$> freshAtom (ReadReg r)

-- | Update the value of a register.
assignReg :: IsSyntaxExtension ext => Reg s tp -> Expr ext s tp -> Generator ext h s t ret ()
assignReg r e = do
  a <-  mkAtom e
  Generator $ addStmt $ SetReg r a

-- | Modify the value of a register.
modifyReg :: IsSyntaxExtension ext => Reg s tp -> (Expr ext s tp -> Expr ext s tp) -> Generator ext h s t ret ()
modifyReg r f = do
  v <- readReg r
  assignReg r $! f v

-- | Modify the value of a register.
modifyRegM :: IsSyntaxExtension ext
           => Reg s tp
           -> (Expr ext s tp -> Generator ext h s t ret (Expr ext s tp))
           -> Generator ext h s t ret ()
modifyRegM r f = do
  v <- readReg r
  v' <- f v
  assignReg r v'

-- | Add a statement to print a value.
addPrintStmt :: IsSyntaxExtension ext => Expr ext s StringType -> Generator ext h s t ret ()
addPrintStmt e = do
  e_a <- mkAtom e
  Generator $ addStmt (Print e_a)

-- | Add an assert statement.
assertExpr :: IsSyntaxExtension ext => Expr ext s BoolType -> Expr ext s StringType -> Generator ext h s t ret ()
assertExpr b e = do
  b_a <- mkAtom b
  e_a <- mkAtom e
  Generator $ addStmt $ Assert b_a e_a

-- | Stash the given CFG away for later retrieval.  This is primarily
--   used when translating inner and anonymous functions in the
--   context of an outer function.
recordCFG :: AnyCFG ext -> Generator ext h s t ret ()
recordCFG g = Generator $ seenFunctions %= (g:)

------------------------------------------------------------------------
-- End

-- | A low-level interface for defining transitions between basic blocks.
--
-- The 'ext' parameter indicates the syntax extension.
-- The 'h' parameter is the ST index used for @'ST' h@.
-- The 's' parameter is part of the CFG.
-- The 't' is parameter is for the user-defined state.
-- The 'ret' parameter is the return type for the CFG.

newtype End ext h s t ret a = End { unEnd :: StateT (IxGeneratorState ext s t ret ()) (ST h) a }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadST h
           )

instance F.MonadFail (End ext h s t ret) where
  fail = fail

instance MonadState (t s) (End ext h s t ret) where
  get = End (use gsState)
  put x = End (gsState .= x)

-- | Create a new block label.
newLabel :: End ext h s t ret (Label s)
newLabel = End $ do
  idx <- use gsNextLabel
  gsNextLabel .= idx + 1
  return (Label idx)

-- | Create a new block label.
newLabelG :: Generator ext h s t ret (Label s)
newLabelG = Generator $ do
  idx <- use gsNextLabel
  gsNextLabel .= idx + 1
  return (Label idx)

-- | Create a new lambda label.
newLambdaLabel :: KnownRepr TypeRepr tp => End ext h s t ret (LambdaLabel s tp)
newLambdaLabel = newLambdaLabel' knownRepr

newLambdaLabel' :: TypeRepr tp -> End ext h s t ret (LambdaLabel s tp)
newLambdaLabel' tpr = End $ do
  p <- use gsPosition
  idx <- use gsNextLabel
  gsNextLabel .= idx + 1

  i <- freshValueIndex

  let lbl = LambdaLabel idx a
      a = Atom { atomPosition = p
               , atomId = i
               , atomSource = LambdaArg lbl
               , typeOfAtom = tpr
               }
  return $! lbl

-- | Create a new lambda label.
newLambdaLabelG :: KnownRepr TypeRepr tp => Generator ext h s t ret (LambdaLabel s tp)
newLambdaLabelG = newLambdaLabelG' knownRepr

newLambdaLabelG' :: TypeRepr tp -> Generator ext h s t ret (LambdaLabel s tp)
newLambdaLabelG' tpr = Generator $ do
  p <- use gsPosition
  idx <- use gsNextLabel
  gsNextLabel .= idx + 1

  i <- freshValueIndex

  let lbl = LambdaLabel idx a
      a = Atom { atomPosition = p
               , atomId = i
               , atomSource = LambdaArg lbl
               , typeOfAtom = tpr
               }
  return $! lbl

-- | End the translation of the current block, and then perform some
-- additional actions.
endCurrentBlock ::
  IsSyntaxExtension ext =>
  TermStmt s ret ->
  End ext h s t ret () ->
  Generator ext h s t ret a
endCurrentBlock term m =
  Generator $ StateContT $ \_cont gs0 ->
  do execStateT (unEnd m) (terminateBlock term gs0)

-- | End the translation of the current block, and then start a new
-- block with the given label.
resume_ ::
  IsSyntaxExtension ext =>
  TermStmt s ret ->
  End ext h s t ret (Label s) ->
  Generator ext h s t ret ()
resume_ term m =
  Generator $ StateContT $ \cont gs0 ->
  do let gs1 = terminateBlock term gs0
     (lbl, gs2) <- runStateT (unEnd m) gs1
     let gs3 = startBlock (LabelID lbl) gs2
     cont () gs3

-- | End the translation of the current block, and then start a new
-- lambda block with the given label.
resume ::
  IsSyntaxExtension ext =>
  TermStmt s ret ->
  End ext h s t ret (LambdaLabel s tp) ->
  Generator ext h s t ret (Expr ext s tp)
resume term m =
  Generator $ StateContT $ \cont gs0 ->
  do let gs1 = terminateBlock term gs0
     (lbl, gs2) <- runStateT (unEnd m) gs1
     let gs3 = startBlock (LambdaID lbl) gs2
     cont (AtomExpr (lambdaAtom lbl)) gs3

defineSomeBlock ::
  IsSyntaxExtension ext =>
  BlockID s ->
  Generator ext h s t ret (TermStmt s ret) ->
  End ext h s t ret ()
defineSomeBlock l next =
  End $ StateT $ \gs0 ->
  do let gs1 = startBlock l gs0
     let cont term gs = return (terminateBlock term gs)
     gs2 <- runStateContT (unGenerator next) cont gs1
     -- Reset current block and state.
     let gs3 = gs2 & gsPosition .~ gs0^.gsPosition
     return ((), gs3)

-- | Define a block with an ordinary label.
defineBlock ::
  IsSyntaxExtension ext =>
  Label s ->
  Generator ext h s t ret (TermStmt s ret) ->
  End ext h s t ret ()
defineBlock l next =
  defineSomeBlock (LabelID l) next

-- | Define a block that has a lambda label.
defineLambdaBlock ::
  IsSyntaxExtension ext =>
  LambdaLabel s i ->
  (Expr ext s i -> Generator ext h s t ret (TermStmt s ret)) ->
  End ext h s t ret ()
defineLambdaBlock l next = do
  defineSomeBlock (LambdaID l) $ next (AtomExpr (lambdaAtom l))

------------------------------------------------------------------------
-- Generator interface

-- | Evaluate an expression, so that it can be more efficiently evaluated later.
forceEvaluation :: IsSyntaxExtension ext => Expr ext s tp -> Generator ext h s t ret (Expr ext s tp)
forceEvaluation e = AtomExpr <$> mkAtom e

-- | Add a statement from the syntax extension to the current basic block.
extensionStmt ::
   IsSyntaxExtension ext =>
   StmtExtension ext (Expr ext s) tp ->
   Generator ext h s t ret (Expr ext s tp)
extensionStmt stmt = do
   stmt' <- traverseFC mkAtom stmt
   AtomExpr <$> freshAtom (EvalExt stmt')

-- | Call a function.
call :: IsSyntaxExtension ext
        => Expr ext s (FunctionHandleType args ret)
        -> Assignment (Expr ext s) args
        -> Generator ext h s t r (Expr ext s ret)
call h args = AtomExpr <$> call' h args

-- | Call a function.
call' :: IsSyntaxExtension ext
        => Expr ext s (FunctionHandleType args ret)
        -> Assignment (Expr ext s) args
        -> Generator ext h s t r (Atom s ret)
call' h args = do
  case exprType h of
    FunctionHandleRepr _ retType -> do
      h_a <- mkAtom h
      args_a <- traverseFC mkAtom args
      freshAtom $ Call h_a args_a retType

-- | Jump to given label.
jump :: IsSyntaxExtension ext => Label s -> Generator ext h s t ret (TermStmt s ret)
jump l = return (Jump l)

-- | Jump to label with output.
jumpToLambda :: IsSyntaxExtension ext => LambdaLabel s tp -> Expr ext s tp -> Generator ext h s t ret (TermStmt s ret)
jumpToLambda lbl v = do
  v_a <- mkAtom v
  return (Output lbl v_a)

-- | Branch between blocks.
branch :: IsSyntaxExtension ext
       => Expr ext s BoolType
       -> Label s
       -> Label s
       -> Generator ext h s t ret (TermStmt s ret)
branch (App (Not e)) x_id y_id = do
  branch e y_id x_id
branch e x_id y_id = do
  a <- mkAtom e
  return (Br a x_id y_id)

------------------------------------------------------------------------
-- Combinators

terminateEarly ::
  IsSyntaxExtension ext => TermStmt s ret -> Generator ext h s t ret a
terminateEarly term =
  Generator $ StateContT $ \_cont gs ->
  return (terminateBlock term gs)

-- | Return from this function.
returnFromFunction ::
  IsSyntaxExtension ext =>
  Expr ext s ret -> Generator ext h s t ret (TermStmt s ret)
returnFromFunction e = do
  e_a <- mkAtom e
  return (Return e_a)

-- | Report error message.
reportError ::
  IsSyntaxExtension ext =>
  Expr ext s StringType -> Generator ext h s t ret a
reportError e = do
  e_a <- mkAtom e
  terminateEarly (ErrorStmt e_a)

-- | If-then-else. Produces a 'Br' statement.
ifte :: (IsSyntaxExtension ext, KnownRepr TypeRepr tp)
     => Expr ext s BoolType
     -> Generator ext h s t ret (Expr ext s tp) -- ^ @true@ branch
     -> Generator ext h s t ret (Expr ext s tp) -- ^ @false@ branch
     -> Generator ext h s t ret (Expr ext s tp)
ifte e x y = do
  e_a <- mkAtom e
  x_id <- newLabelG
  y_id <- newLabelG
  resume (Br e_a x_id y_id) $ do
    c_id <- newLambdaLabel
    defineBlock x_id $ x >>= jumpToLambda c_id
    defineBlock y_id $ y >>= jumpToLambda c_id
    return c_id

ifteM :: (IsSyntaxExtension ext, KnownRepr TypeRepr tp)
     => Generator ext h s t ret (Expr ext s BoolType)
     -> Generator ext h s t ret (Expr ext s tp)
     -> Generator ext h s t ret (Expr ext s tp)
     -> Generator ext h s t ret (Expr ext s tp)
ifteM em x y = do { m <- em; ifte m x y }

ifte_ :: IsSyntaxExtension ext
      => Expr ext s BoolType
      -> Generator ext h s t ret ()
      -> Generator ext h s t ret ()
      -> Generator ext h s t ret ()
ifte_ e x y = do
  e_a <- mkAtom e
  x_id <- newLabelG
  y_id <- newLabelG
  resume_ (Br e_a x_id y_id) $ do
    c_id <- newLabel
    defineBlock x_id $ x >> jump c_id
    defineBlock y_id $ y >> jump c_id
    return c_id

-- | Run a computation when a condition is true.
whenCond :: IsSyntaxExtension ext
         => Expr ext s BoolType
         -> Generator ext h s t ret ()
         -> Generator ext h s t ret ()
whenCond e x = do
  e_a <- mkAtom e
  t_id <- newLabelG
  c_id <- newLabelG
  resume_ (Br e_a t_id c_id) $ do
    defineBlock t_id $ x >> jump c_id
    return c_id

-- | Run a computation when a condition is false.
unlessCond :: IsSyntaxExtension ext
           => Expr ext s BoolType
           -> Generator ext h s t ret ()
           -> Generator ext h s t ret ()
unlessCond e x = do
  e_a <- mkAtom e
  f_id <- newLabelG
  c_id <- newLabelG
  resume_ (Br e_a c_id f_id) $ do
    defineBlock f_id $ x >> jump c_id
    return c_id

data MatchMaybe j r
   = MatchMaybe
   { onJust :: j -> r
   , onNothing :: r
   }

caseMaybe :: IsSyntaxExtension ext
          => Expr ext s (MaybeType tp)
          -> TypeRepr r
          -> MatchMaybe (Expr ext s tp) (Generator ext h s t ret (Expr ext s r))
          -> Generator ext h s t ret (Expr ext s r)
caseMaybe v retType cases = do
  v_a <- mkAtom v
  let etp = case exprType v of
              MaybeRepr etp' -> etp'
  j_id <- newLambdaLabelG' etp
  n_id <- newLabelG
  resume (MaybeBranch etp v_a j_id n_id) $ do
    c_id <- newLambdaLabel' retType
    defineLambdaBlock j_id $ onJust cases >=> jumpToLambda c_id
    defineBlock       n_id $ onNothing cases >>= jumpToLambda c_id
    return c_id

caseMaybe_ :: IsSyntaxExtension ext
           => Expr ext s (MaybeType tp)
           -> MatchMaybe (Expr ext s tp) (Generator ext h s t ret ())
           -> Generator ext h s t ret ()
caseMaybe_ v cases = do
  v_a <- mkAtom v
  let etp = case exprType v of
              MaybeRepr etp' -> etp'
  j_id <- newLambdaLabelG' etp
  n_id <- newLabelG
  resume_ (MaybeBranch etp v_a j_id n_id) $ do
    c_id <- newLabel
    defineLambdaBlock j_id $ \e -> onJust cases e >> jump c_id
    defineBlock       n_id $ onNothing cases >> jump c_id
    return c_id

fromJustExpr :: IsSyntaxExtension ext
             => Expr ext s (MaybeType tp)
             -> Expr ext s StringType
             -> Generator ext h s t ret (Expr ext s tp)
fromJustExpr e msg = do
  e_a <- mkAtom e
  let etp = case exprType e of
              MaybeRepr etp' -> etp'
  j_id <- newLambdaLabelG' etp
  n_id <- newLabelG
  resume (MaybeBranch etp e_a j_id n_id) $ do
    c_id <- newLambdaLabel' etp
    defineLambdaBlock j_id $ jumpToLambda c_id
    defineBlock       n_id $ reportError msg
    return c_id

-- | This asserts that the value in the expression is a @Just@ value, and
-- returns the underlying value.
assertedJustExpr :: IsSyntaxExtension ext
                 => Expr ext s (MaybeType tp)
                 -> Expr ext s StringType
                 -> Generator ext h s t ret (Expr ext s tp)
assertedJustExpr e msg =
  case exprType e of
    MaybeRepr tp ->
      forceEvaluation $! App (FromJustValue tp e msg)

while :: IsSyntaxExtension ext
      => (Position, Generator ext h s t ret (Expr ext s BoolType))
      -> (Position, Generator ext h s t ret ())
      -> Generator ext h s t ret ()
while (pcond,cond) (pbody,body) = do
  cond_lbl <- newLabelG
  loop_lbl <- newLabelG
  exit_lbl <- newLabelG
  resume_ (Jump cond_lbl) $ do

    p <- End $ use gsPosition

    End $ gsPosition .= pcond
    defineBlock cond_lbl $ do
      b <- cond
      branch b loop_lbl exit_lbl

    End $ gsPosition .= pbody
    defineBlock loop_lbl $ do
      body
      jump cond_lbl
    -- Reset position
    End $ gsPosition .= p
    return exit_lbl

------------------------------------------------------------------------
-- CFG

cfgFromGenerator :: FnHandle init ret
                 -> IxGeneratorState ext s t ret i
                 -> CFG ext s init ret
cfgFromGenerator h s =
  CFG { cfgHandle = h
      , cfgBlocks = Fold.toList (s^.gsBlocks)
      }

-- | Given the arguments, this returns the initial state, and an action for
-- computing the return value.
type FunctionDef ext h t init ret =
  forall s .
  Assignment (Atom s) init ->
  (t s, Generator ext h s t ret (Expr ext s ret))

-- | The main API for generating CFGs for a Crucible function.
--
--   The given @FunctionDef@ action is run to generate a registerized
--   CFG.  The return value of this action is the generated CFG, and a
--   list of CFGs for any other auxiliary function definitions
--   generated along the way (e.g., for anonymous or inner functions).
defineFunction :: IsSyntaxExtension ext
               => Position                 -- ^ Source position for the function
               -> FnHandle init ret        -- ^ Handle for the generated function
               -> FunctionDef ext h t init ret -- ^ Generator action and initial state
               -> ST h (SomeCFG ext init ret, [AnyCFG ext]) -- ^ Generated CFG and inner function definitions
defineFunction p h f = seq h $ do
  let argTypes = handleArgTypes h

  let inputs = mkInputAtoms p argTypes
  let inputSet = Set.fromList (toListFC (Some . AtomValue) inputs)
  let (init_state, action) = f $! inputs
  let cbs = initCurrentBlockState inputSet (LabelID (Label 0))
  let ts = GS { _gsBlocks = Seq.empty
              , _gsNextLabel = 1
              , _gsNextValue  = Ctx.sizeInt (Ctx.size argTypes)
              , _gsCurrent = cbs
              , _gsPosition = p
              , _gsState = init_state
              , _seenFunctions = []
              }
  let go = returnFromFunction =<< action
  let cont term gs = return (terminateBlock term gs)
  ts' <- runStateContT (unGenerator go) cont $! ts
  return (SomeCFG (cfgFromGenerator h ts'), ts'^.seenFunctions)
