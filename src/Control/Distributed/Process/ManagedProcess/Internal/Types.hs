{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}
{-# LANGUAGE Rank2Types                 #-}

-- | Types used throughout the ManagedProcess framework
module Control.Distributed.Process.ManagedProcess.Internal.Types
  ( -- * Exported data types
    InitResult(..)
  , Condition(..)
  , ProcessAction(..)
  , ProcessReply(..)
  , Action
  , Reply
  , ActionHandler
  , CallHandler
  , CastHandler
  , StatelessHandler
  , DeferredCallHandler
  , StatelessCallHandler
  , InfoHandler
  , ChannelHandler
  , StatelessChannelHandler
  , InitHandler
  , ShutdownHandler
  , ExitState(..)
  , isCleanShutdown
  , exitState
  , TimeoutHandler
  , UnhandledMessagePolicy(..)
  , ProcessDefinition(..)
  , Priority(..)
  , DispatchPriority(..)
  , PrioritisedProcessDefinition(..)
  , RecvTimeoutPolicy(..)
  , ControlChannel(..)
  , newControlChan
  , ControlPort(..)
  , channelControlPort
  , Dispatcher(..)
  , ExternDispatcher(..)
  , DeferredDispatcher(..)
  , ExitSignalDispatcher(..)
  , MessageMatcher(..)
  , ExternMatcher(..)
  , DynMessageHandler(..)
  , Message(..)
  , CallResponse(..)
  , CallId
  , CallRef(..)
  , CallRejected(..)
  , makeRef
  , initCall
  , unsafeInitCall
  , waitResponse
  ) where

import Control.Concurrent.STM (STM)
import Control.Distributed.Process hiding (Message, finally)
import Control.Monad.Catch (finally)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Extras
  ( Recipient(..)
  , ExitReason(..)
  , Addressable
  , Resolvable(..)
  , Routable(..)
  , NFSerializable
  )
import Control.Distributed.Process.Extras.Internal.Types
  ( resolveOrDie
  )
import Control.Distributed.Process.Extras.Time
import Control.DeepSeq (NFData(..))
import Data.Binary hiding (decode)
import Data.Typeable (Typeable)

import Prelude hiding (init)

import GHC.Generics

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | wrapper for a @MonitorRef@
type CallId = MonitorRef

-- | Wraps a consumer of the call API
newtype CallRef a = CallRef { unCaller :: (Recipient, CallId) }
  deriving (Eq, Show, Typeable, Generic)

instance Binary (CallRef a) where
instance NFData (CallRef a) where rnf (CallRef x) = rnf x `seq` ()

-- | Creates a @CallRef@ for the given @Recipient@ and @CallId@
makeRef :: Recipient -> CallId -> CallRef a
makeRef r c = CallRef (r, c)

-- | @Message@ type used internally by the call, cast, and rpcChan APIs.
data Message a b =
    CastMessage a
  | CallMessage a (CallRef b)
  | ChanMessage a (SendPort b)
  deriving (Typeable, Generic)

instance (Serializable a, Serializable b) => Binary (Message a b) where
instance (NFSerializable a, NFSerializable b) => NFData (Message a b) where
  rnf (CastMessage a) = rnf a `seq` ()
  rnf (CallMessage a b) = rnf a `seq` rnf b `seq` ()
  rnf (ChanMessage a b) = rnf a `seq` rnf b `seq` ()
deriving instance (Eq a, Eq b) => Eq (Message a b)
deriving instance (Show a, Show b) => Show (Message a b)

-- | Response type for the call API
data CallResponse a = CallResponse a CallId
  deriving (Typeable, Generic)

instance Serializable a => Binary (CallResponse a)
instance NFSerializable a => NFData (CallResponse a) where
  rnf (CallResponse a c) = rnf a `seq` rnf c `seq` ()
deriving instance Eq a => Eq (CallResponse a)
deriving instance Show a => Show (CallResponse a)

data CallRejected = CallRejected String CallId
  deriving (Typeable, Generic, Show, Eq)
instance Binary CallRejected where
instance NFData CallRejected where

instance Resolvable (CallRef a) where
  resolve (CallRef (r, _)) = resolve r

instance Routable (CallRef a) where
  sendTo  (CallRef (client, tag)) msg = sendTo client (CallResponse msg tag)
  unsafeSendTo (CallRef (c, tag)) msg = unsafeSendTo c (CallResponse msg tag)

-- | Return type for and 'InitHandler' expression.
data InitResult s =
    InitOk s Delay {-
        ^ a successful initialisation, initial state and timeout -}
  | InitStop String {-
        ^ failed initialisation and the reason, this will result in an error -}
  | InitIgnore {-
        ^ the process has decided not to continue starting - this is not an error -}
  deriving (Typeable)

-- | The action taken by a process after a handler has run and its updated state.
-- See "Control.Distributed.Process.ManagedProcess.Server.continue"
--     "Control.Distributed.Process.ManagedProcess.Server.timeoutAfter"
--     "Control.Distributed.Process.ManagedProcess.Server.hibernate"
--     "Control.Distributed.Process.ManagedProcess.Server.stop"
--     "Control.Distributed.Process.ManagedProcess.Server.stopWith"
--
data ProcessAction s =
    ProcessSkip
  | ProcessContinue  s              -- ^ continue with (possibly new) state
  | ProcessTimeout   Delay        s -- ^ timeout if no messages are received
  | ProcessHibernate TimeInterval s -- ^ hibernate for /delay/
  | ProcessStop      ExitReason     -- ^ stop the process, giving @ExitReason@
  | ProcessStopping  s ExitReason   -- ^ stop the process with @ExitReason@, with updated state

-- | Returned from handlers for the synchronous 'call' protocol, encapsulates
-- the reply data /and/ the action to take after sending the reply. A handler
-- can return @NoReply@ if they wish to ignore the call.
data ProcessReply r s =
    ProcessReply r (ProcessAction s)
  | ProcessReject String (ProcessAction s)
  | NoReply (ProcessAction s)

-- | Wraps a predicate that is used to determine whether or not a handler
-- is valid based on some combination of the current process state, the
-- type and/or value of the input message or both.
data Condition s m =
    Condition (s -> m -> Bool)  -- ^ predicated on the process state /and/ the message
  | State     (s -> Bool)       -- ^ predicated on the process state only
  | Input     (m -> Bool)       -- ^ predicated on the input message only

-- | Informs a /shutdown handler/ of whether it is running due to a clean
-- shutdown, or in response to an unhandled exception.
data ExitState s = CleanShutdown s -- ^ given when an ordered shutdown is underway
                 | LastKnown s     {-
                  ^ given due to an unhandled exception, passing the last known state -}

isCleanShutdown :: ExitState s -> Bool
isCleanShutdown (CleanShutdown _) = True
isCleanShutdown _                 = False

exitState :: ExitState s -> s
exitState (CleanShutdown s) = s
exitState (LastKnown s)     = s

-- | An action (server state transition) in the @Process@ monad
type Action s = Process (ProcessAction s)

-- | An action (server state transition) causing a reply to a  caller, in the
-- @Process@ monad
type Reply b s = Process (ProcessReply b s)

-- | An expression used to handle a message
type ActionHandler s a = s -> a -> Action s

-- | An expression used to handle a message and providing a reply
type CallHandler s a b = s -> a -> Reply b s

-- | An expression used to ignore server state during handling
type StatelessHandler s a = a -> (s -> Action s)

-- | An expression used to handle a /call/ message where the reply is deferred
-- via the 'CallRef'
type DeferredCallHandler s a b = CallRef b -> CallHandler s a b

-- | An expression used to handle a /call/ message ignoring server state
type StatelessCallHandler s a b = CallRef b -> a -> Reply b s

-- | An expression used to handle a /cast/ message
type CastHandler s a = ActionHandler s a

-- | An expression used to handle an /info/ message
type InfoHandler s a = ActionHandler s a

-- | An expression used to handle a /channel/ message
type ChannelHandler s a b = SendPort b -> ActionHandler s a

-- | An expression used to handle a /channel/ message in a stateless process
type StatelessChannelHandler s a b = SendPort b -> StatelessHandler s a

-- | An expression used to initialise a process with its state
type InitHandler a s = a -> Process (InitResult s)

-- | An expression used to handle process termination
type ShutdownHandler s = ExitState s -> ExitReason -> Process ()

-- | An expression used to handle process timeouts
type TimeoutHandler s = ActionHandler s Delay

-- dispatching to implementation callbacks

-- | Provides a means for servers to listen on a separate, typed /control/
-- channel, thereby segregating the channel from their regular
-- (and potentially busy) mailbox.
newtype ControlChannel m =
  ControlChannel {
      unControl :: (SendPort (Message m ()), ReceivePort (Message m ()))
    }

-- | Creates a new 'ControlChannel'.
newControlChan :: (Serializable m) => Process (ControlChannel m)
newControlChan = fmap ControlChannel newChan

-- | The writable end of a 'ControlChannel'.
--
newtype ControlPort m =
  ControlPort {
      unPort :: SendPort (Message m ())
    } deriving (Show)
deriving instance (Serializable m) => Binary (ControlPort m)
instance Eq (ControlPort m) where
  a == b = unPort a == unPort b

-- | Obtain an opaque expression for communicating with a 'ControlChannel'.
--
channelControlPort :: ControlChannel m
                   -> ControlPort m
channelControlPort cc = ControlPort $ fst $ unControl cc

-- | Provides dispatch from cast and call messages to a typed handler.
data Dispatcher s =
    forall a b . (Serializable a, Serializable b) =>
    Dispatch
    {
      dispatch :: s -> Message a b -> Process (ProcessAction s)
    }
  | forall a b . (Serializable a, Serializable b) =>
    DispatchIf
    {
      dispatch   :: s -> Message a b -> Process (ProcessAction s)
    , dispatchIf :: s -> Message a b -> Bool
    }

-- | Provides dispatch for channels and STM actions
data ExternDispatcher s =
    forall a b . (Serializable a, Serializable b) =>
    DispatchCC  -- control channel dispatch
    {
      channel      :: ReceivePort (Message a b)
    , dispatchChan :: s -> Message a b -> Process (ProcessAction s)
    }
  | forall a . (Serializable a) =>
    DispatchSTM -- arbitrary STM actions
    {
      stmAction   :: STM a
    , dispatchStm :: s -> a -> Process (ProcessAction s)
    , matchStm    :: Match P.Message
    , matchAnyStm :: forall m . (P.Message -> m) -> Match m
    }

-- | Provides dispatch for any input, returns 'Nothing' for unhandled messages.
data DeferredDispatcher s =
  DeferredDispatcher
  {
    dispatchInfo :: s
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
  }

-- | Provides dispatch for any exit signal - returns 'Nothing' for unhandled exceptions
data ExitSignalDispatcher s =
  ExitSignalDispatcher
  {
    dispatchExit :: s
                 -> ProcessId
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
  }

-- | Defines the means of dispatching inbound messages to a handler
class MessageMatcher d where
  matchDispatch :: UnhandledMessagePolicy -> s -> d s -> Match (ProcessAction s)

instance MessageMatcher Dispatcher where
  matchDispatch _ s (Dispatch    d)      = match   (d s)
  matchDispatch _ s (DispatchIf  d cond) = matchIf (cond s) (d s)

instance MessageMatcher ExternDispatcher where
  matchDispatch _ s (DispatchCC  c d)     = matchChan c (d s)
  matchDispatch _ s (DispatchSTM c d _ _) = matchSTM  c (d s)

class ExternMatcher d where
  matchExtern :: UnhandledMessagePolicy -> s -> d s -> Match P.Message

  matchMapExtern :: forall m s . UnhandledMessagePolicy
                 -> s -> (P.Message -> m) -> d s -> Match m

instance ExternMatcher ExternDispatcher where
  matchExtern _ _ (DispatchCC  c _)     = matchChan c (return . unsafeWrapMessage)
  matchExtern _ _ (DispatchSTM _ _ m _) = m

  matchMapExtern _ _ f (DispatchCC c _)      = matchChan c (return . f . unsafeWrapMessage)
  matchMapExtern _ _ f (DispatchSTM _ _ _ p) = p f

-- | Maps handlers to a dynamic action that can take place outside of a
-- expect/recieve block.
class DynMessageHandler d where
  dynHandleMessage :: UnhandledMessagePolicy
                   -> s
                   -> d s
                   -> P.Message
                   -> Process (Maybe (ProcessAction s))

instance DynMessageHandler Dispatcher where
  dynHandleMessage _ s (Dispatch       d)   msg = handleMessage   msg (d s)
  dynHandleMessage _ s (DispatchIf     d c) msg = handleMessageIf msg (c s) (d s)

instance DynMessageHandler ExternDispatcher where
  dynHandleMessage _ s (DispatchCC  _ d)     msg = handleMessage msg (d s)
  dynHandleMessage _ s (DispatchSTM _ d _ _) msg = handleMessage msg (d s)

instance DynMessageHandler DeferredDispatcher where
  dynHandleMessage _ s (DeferredDispatcher d) = d s

-- | Priority of a message, encoded as an @Int@
newtype Priority a = Priority { getPrio :: Int }

-- | Dispatcher for prioritised handlers
data DispatchPriority s =
    PrioritiseCall
    {
      prioritise :: s -> P.Message -> Process (Maybe (Int, P.Message))
    }
  | PrioritiseCast
    {
      prioritise :: s -> P.Message -> Process (Maybe (Int, P.Message))
    }
  | PrioritiseInfo
    {
      prioritise :: s -> P.Message -> Process (Maybe (Int, P.Message))
    }

-- | For a 'PrioritisedProcessDefinition', this policy determines for how long
-- the /receive loop/ should continue draining the process' mailbox before
-- processing its received mail (in priority order).
--
-- If a prioritised /managed process/ is receiving a lot of messages (into its
-- /real/ mailbox), the server might never get around to actually processing its
-- inputs. This (mandatory) policy provides a guarantee that eventually (i.e.,
-- after a specified number of received messages or time interval), the server
-- will stop removing messages from its mailbox and process those it has already
-- received.
--
data RecvTimeoutPolicy = RecvMaxBacklog Int | RecvTimer TimeInterval
  deriving (Typeable)

-- | A @ProcessDefinition@ decorated with @DispatchPriority@ for certain
-- input domains.
data PrioritisedProcessDefinition s =
  PrioritisedProcessDefinition
  {
    processDef  :: ProcessDefinition s
  , priorities  :: [DispatchPriority s]
  , recvTimeout :: RecvTimeoutPolicy
  }

-- | Policy for handling unexpected messages, i.e., messages which are not
-- sent using the 'call' or 'cast' APIs, and which are not handled by any of the
-- 'handleInfo' handlers.
data UnhandledMessagePolicy =
    Terminate  -- ^ stop immediately, giving @ExitOther "UnhandledInput"@ as the reason
  | DeadLetter ProcessId -- ^ forward the message to the given recipient
  | Log                  -- ^ log messages, then behave identically to @Drop@
  | Drop                 -- ^ dequeue and then drop/ignore the message

-- | Stores the functions that determine runtime behaviour in response to
-- incoming messages and a policy for responding to unhandled messages.
data ProcessDefinition s = ProcessDefinition {
    apiHandlers    :: [Dispatcher s]       -- ^ functions that handle call/cast messages
  , infoHandlers   :: [DeferredDispatcher s] -- ^ functions that handle non call/cast messages
  , externHandlers :: [ExternDispatcher s] -- ^ functions that handle control channel and STM inputs
  , exitHandlers   :: [ExitSignalDispatcher s] -- ^ functions that handle exit signals
  , timeoutHandler :: TimeoutHandler s   -- ^ a function that handles timeouts
  , shutdownHandler :: ShutdownHandler s -- ^ a function that is run just before the process exits
  , unhandledMessagePolicy :: UnhandledMessagePolicy -- ^ how to deal with unhandled messages
  }

-- note [rpc calls]
-- One problem with using plain expect/receive primitives to perform a
-- synchronous (round trip) call is that a reply matching the expected type
-- could come from anywhere! The Call.hs module uses a unique integer tag to
-- distinguish between inputs but this is easy to forge, and forces all callers
-- to maintain a tag pool, which is quite onerous.
--
-- Here, we use a private (internal) tag based on a 'MonitorRef', which is
-- guaranteed to be unique per calling process (in the absence of mallicious
-- peers). This is handled throughout the roundtrip, such that the reply will
-- either contain the CallId (i.e., the ame 'MonitorRef' with which we're
-- tracking the server process) or we'll see the server die.
--
-- Of course, the downside to all this is that the monitoring and receiving
-- clutters up your mailbox, and if your mailbox is extremely full, could
-- incur delays in delivery. The callAsync function provides a neat
-- work-around for that, relying on the insulation provided by Async.

-- TODO: Generify this /call/ API and use it in Call.hs to avoid tagging

-- TODO: the code below should be moved elsewhere. Maybe to Client.hs?
initCall :: forall s a b . (Addressable s, Serializable a, Serializable b)
         => s -> a -> Process (CallRef b)
initCall sid msg = do
  pid <- resolveOrDie sid "initCall: unresolveable address "
  mRef <- monitor pid
  self <- getSelfPid
  let cRef = makeRef (Pid self) mRef in do
    sendTo pid (CallMessage msg cRef :: Message a b)
    return cRef

unsafeInitCall :: forall s a b . ( Addressable s
                                 , NFSerializable a
                                 , NFSerializable b
                                 )
         => s -> a -> Process (CallRef b)
unsafeInitCall sid msg = do
  pid <- resolveOrDie sid "unsafeInitCall: unresolveable address "
  mRef <- monitor pid
  self <- getSelfPid
  let cRef = makeRef (Pid self) mRef in do
    unsafeSendTo pid (CallMessage msg cRef  :: Message a b)
    return cRef

waitResponse :: forall b. (Serializable b)
             => Maybe TimeInterval
             -> CallRef b
             -> Process (Maybe (Either ExitReason b))
waitResponse mTimeout cRef =
  let (_, mRef) = unCaller cRef
      matchers  = [ matchIf (\((CallResponse _ ref) :: CallResponse b) -> ref == mRef)
                            (\((CallResponse m _) :: CallResponse b) -> return (Right m))
                  , matchIf (\((CallRejected _ ref)) -> ref == mRef)
                            (\(CallRejected s _) -> return (Left $ ExitOther $ s))
                  , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                      (\(ProcessMonitorNotification _ _ r) -> return (Left (err r)))
                  ]
      err r     = ExitOther $ show r in
    case mTimeout of
      (Just ti) -> finally (receiveTimeout (asTimeout ti) matchers) (unmonitor mRef)
      Nothing   -> finally (fmap Just (receiveWait matchers)) (unmonitor mRef)
