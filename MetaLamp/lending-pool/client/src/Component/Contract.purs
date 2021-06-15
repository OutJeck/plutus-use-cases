module Component.Contract where

import Prelude
import Business.AaveUser (UserContractId)
import Business.AaveUser as AaveUser
import Capability.LogMessages (class LogMessages)
import Capability.PollContract (class PollContract)
import Component.AmountForm as AmountForm
import Component.Utils (runRD)
import Control.Monad.Except (lift, runExceptT, throwError)
import Data.Array (mapWithIndex)
import Data.BigInteger (BigInteger)
import Data.Either (either)
import Data.Foldable (find)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Json.JsonTuple (JsonTuple(..))
import Data.Lens (Lens')
import Data.Lens.Record (prop)
import Data.Maybe (Maybe(..))
import Data.Symbol (SProxy(..))
import Data.Tuple (Tuple(..))
import Halogen as H
import Halogen.HTML as HH
import Network.RemoteData (RemoteData(..))
import Network.RemoteData as RD
import Plutus.Contracts.Endpoints (BorrowParams(..), DepositParams(..), RepayParams(..), WithdrawParams(..))
import Plutus.V1.Ledger.Crypto (PubKeyHash)
import Plutus.V1.Ledger.Value (AssetClass(..), TokenName(..), Value)
import View.FundsTable (fundsTable)

type State
  = { userContractId :: UserContractId
    , walletPubKey :: PubKeyHash
    , reserves :: Array { amount :: BigInteger, asset :: AssetClass }
    , userFunds :: Value
    , deposit :: RemoteData String Unit
    , withdraw :: RemoteData String Unit
    , borrow :: RemoteData String Unit
    , repay :: RemoteData String Unit
    , submit :: RemoteData String Unit
    }

_deposit :: Lens' State (RemoteData String Unit)
_deposit = prop (SProxy :: SProxy "deposit")

_withdraw :: Lens' State (RemoteData String Unit)
_withdraw = prop (SProxy :: SProxy "withdraw")

_borrow :: Lens' State (RemoteData String Unit)
_borrow = prop (SProxy :: SProxy "borrow")

_repay :: Lens' State (RemoteData String Unit)
_repay = prop (SProxy :: SProxy "repay")

_submit :: Lens' State (RemoteData String Unit)
_submit = prop (SProxy :: SProxy "submit")

type Input
  = { userContractId :: UserContractId
    , walletPubKey :: PubKeyHash
    , reserves :: Array { amount :: BigInteger, asset :: AssetClass }
    , userFunds :: Value
    }

data Output
  = SubmitSuccess

initialState :: Input -> State
initialState { userFunds, userContractId, walletPubKey, reserves } =
  { userContractId
  , walletPubKey
  , reserves
  , userFunds
  , withdraw: NotAsked
  , deposit: NotAsked
  , borrow: NotAsked
  , repay: NotAsked
  , submit: NotAsked
  }

data Action
  = Deposit { amount :: BigInteger, asset :: AssetClass }
  | Withdraw { amount :: BigInteger, asset :: AssetClass }
  | Borrow { amount :: BigInteger, asset :: AssetClass }
  | Repay { amount :: BigInteger, asset :: AssetClass }
  | OnSubmitAmount SubmitOperation AmountForm.Output

-- potentially should be separate actions - just a convenience for now, while they are identical
data SubmitOperation
  = SubmitDeposit
  | SubmitWithdraw
  | SubmitBorrow
  | SubmitRepay

derive instance genericSubmitOperation :: Generic SubmitOperation _

instance showSubmitOperation :: Show SubmitOperation where
  show = genericShow

type Slots
  = ( amountForm :: forall query. H.Slot query AmountForm.Output Int )

_amountForm = SProxy :: SProxy "amountForm"

component ::
  forall m query.
  LogMessages m =>
  PollContract m =>
  H.Component HH.HTML query Input Output m
component =
  H.mkComponent
    { initialState
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction }
    }
  where
  handleAction :: Action -> H.HalogenM State Action Slots Output m Unit
  handleAction = case _ of
    Deposit { amount, asset } ->
      runRD _deposit <<< runExceptT
        $ do
            { userContractId, walletPubKey } <- lift H.get
            lift (AaveUser.deposit userContractId $ DepositParams { dpAmount: amount, dpAsset: asset, dpOnBehalfOf: walletPubKey })
              >>= either (throwError <<< show) (const <<< lift <<< H.raise $ SubmitSuccess)
    Withdraw { amount, asset } ->
      runRD _withdraw <<< runExceptT
        $ do
            { userContractId, walletPubKey } <- lift H.get
            lift (AaveUser.withdraw userContractId $ WithdrawParams { wpAmount: amount, wpAsset: asset, wpUser: walletPubKey })
              >>= either (throwError <<< show) (const <<< lift <<< H.raise $ SubmitSuccess)
    Borrow { amount, asset } ->
      runRD _borrow <<< runExceptT
        $ do
            { userContractId, walletPubKey } <- lift H.get
            lift (AaveUser.borrow userContractId $ BorrowParams { bpAmount: amount, bpAsset: asset, bpOnBehalfOf: walletPubKey })
              >>= either (throwError <<< show) (const <<< lift <<< H.raise $ SubmitSuccess)
    Repay { amount, asset } ->
      runRD _repay <<< runExceptT
        $ do
            { userContractId, walletPubKey } <- lift H.get
            lift (AaveUser.repay userContractId $ RepayParams { rpAmount: amount, rpAsset: asset, rpOnBehalfOf: walletPubKey })
              >>= either (throwError <<< show) (const <<< lift <<< H.raise $ SubmitSuccess)
    OnSubmitAmount operation (AmountForm.Submit { name, amount }) ->
      runRD _submit <<< runExceptT
        $ do
            { reserves } <- lift H.get
            case find (\r -> getAssetName r.asset == name) reserves of
              Just ({ asset }) -> case operation of
                SubmitDeposit -> do
                  lift $ handleAction (Deposit { amount, asset })
                  { deposit } <- lift H.get
                  RD.maybe
                    (throwError $ "Submit deposit failed: " <> show deposit)
                    (const <<< pure $ unit)
                    deposit
                SubmitWithdraw -> do
                  lift $ handleAction (Withdraw { amount, asset })
                  { withdraw } <- lift H.get
                  RD.maybe
                    (throwError $ "Submit withdraw failed: " <> show withdraw)
                    (const <<< pure $ unit)
                    withdraw
                SubmitBorrow -> do
                  lift $ handleAction (Borrow { amount, asset })
                  { borrow } <- lift H.get
                  RD.maybe
                    (throwError $ "Submit borrow failed: " <> show borrow)
                    (const <<< pure $ unit)
                    borrow
                SubmitRepay -> do
                  lift $ handleAction (Repay { amount, asset })
                  { repay } <- lift H.get
                  RD.maybe
                    (throwError $ "Submit repay failed: " <> show repay)
                    (const <<< pure $ unit)
                    repay
              Nothing -> throwError "Asset name not found"

  render :: State -> H.ComponentHTML Action Slots m
  render state =
    HH.div_
      [ HH.div_ [ HH.h2_ [ HH.text "User funds" ], fundsTable state.userFunds ]
      , case state.submit of
          NotAsked -> HH.div_ []
          Loading -> HH.div_ []
          Failure e -> HH.div_ [ HH.text $ "Error: " <> show e ]
          Success _ -> HH.div_ []
      , HH.div_
          $ mapWithIndex
              ( \index (Tuple title operation) ->
                  HH.h2_
                    [ HH.text title
                    , HH.slot _amountForm index AmountForm.component (reservesToAmounts state.reserves) (Just <<< (OnSubmitAmount operation))
                    ]
              )
              [ Tuple "Deposit" SubmitDeposit, Tuple "Withdraw" SubmitWithdraw, Tuple "Borrow" SubmitBorrow, Tuple "Repay" SubmitRepay ]
      ]

reservesToAmounts :: Array { amount :: BigInteger, asset :: AssetClass } -> Array AmountForm.AmountInfo
reservesToAmounts = map (\{ asset, amount } -> { name: getAssetName asset, amount })

getAssetName :: AssetClass -> String
getAssetName (AssetClass { unAssetClass: JsonTuple (Tuple _ (TokenName { unTokenName: name })) }) = name
