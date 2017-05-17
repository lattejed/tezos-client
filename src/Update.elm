module Update exposing (update, Msg(..), setRoute)

import Date
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Json.Decode.Pipeline as Decode
import Http
import List.Extra as List
import Set
import Time exposing (Time)
import Model exposing (..)
import Data.Schema as Schema exposing (SchemaData, SchemaName, decodeSchema, collapseTrees)
import Data.Chain as Chain exposing (Block, BlockID, Operation, OperationID)
import Data.Request exposing (URL)
import Page exposing (Page)
import Request.Block
import Request.Operation
import Request.Schema exposing (getSchema)
import Route exposing (Route)


type Msg
    = LoadBlocks (Result Http.Error Chain.BlocksData)
    | LoadSchema SchemaName (Result Http.Error SchemaData)
    | LoadOperation (Result Http.Error Operation)
    | LoadBlockOperations BlockID (Result Http.Error Chain.BlockOperations)
    | LoadParsedOperation OperationID (Result Http.Error Chain.ParsedOperation)
    | SchemaMsg SchemaName Schema.Msg
    | ShowBlock BlockID
    | ShowOperation OperationID
    | ShowBranch BlockID
    | LoadHeads (Result Http.Error Chain.BlocksData)
    | Tick Time
    | SetRoute (Maybe Route)
    | ClearErrors


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    updatePage (getPage model.pageState) msg model


updatePage : Page -> Msg -> Model -> ( Model, Cmd Msg )
updatePage page msg model =
    case ( msg, page ) |> Debug.log "update" of
        ( LoadBlocks blocksMaybe, _ ) ->
            case blocksMaybe of
                Ok blockChains ->
                    loadBlocks model blockChains

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        ( LoadSchema schemaName schemaMaybe, _ ) ->
            case schemaMaybe of
                Ok schemaData ->
                    ( { model | schemaData = Dict.insert schemaName (collapseTrees schemaData) model.schemaData }
                    , Cmd.none
                    )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        ( SchemaMsg name msg, _ ) ->
            let
                newSchemaMaybe : Maybe SchemaData
                newSchemaMaybe =
                    Dict.get name model.schemaData |> Maybe.map (Schema.update msg)
            in
                case newSchemaMaybe of
                    Just newSchema ->
                        ( { model | schemaData = Dict.insert name newSchema model.schemaData }, Cmd.none )

                    Nothing ->
                        let
                            _ =
                                Debug.log "Failed to find schema" name
                        in
                            ( model, Cmd.none )

        ( LoadOperation operationResult, _ ) ->
            case operationResult of
                Ok operation ->
                    let
                        newChain =
                            Chain.loadOperation model.chain operation
                    in
                        ( { model | chain = newChain }, Cmd.none )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        ( LoadParsedOperation operationId parseResult, _ ) ->
            case parseResult of
                Ok parse ->
                    let
                        newChain =
                            Chain.loadParsedOperation model.chain operationId parse
                    in
                        ( { model | chain = newChain }, Cmd.none )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        ( LoadBlockOperations blockhash result, _ ) ->
            case result of
                Ok operationListList ->
                    ( { model | chain = Chain.addBlockOperations model.chain blockhash operationListList }
                    , Cmd.none
                    )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        ( LoadHeads headsResult, _ ) ->
            case headsResult of
                Ok heads ->
                    loadHeads model heads

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        ( ShowBlock blockhash, _ ) ->
            ( model
            , Cmd.batch
                [ getBlockOperationDetails model blockhash
                , Route.newUrl (Route.Block blockhash)
                ]
            )

        ( ShowOperation operationId, _ ) ->
            ( model, Route.newUrl (Route.Operation operationId) )

        ( ShowBranch hash, _ ) ->
            ( model
            , getBranch model hash
            )

        ( Tick time, _ ) ->
            ( { model | now = Date.fromTime time }
            , Request.Block.getHeads model.nodeUrl |> Http.send LoadHeads
            )

        ( SetRoute route, _ ) ->
            setRoute route model

        ( ClearErrors, _ ) ->
            ( { model | errors = [] }, Cmd.none )


setRoute : Maybe Route -> Model -> ( Model, Cmd Msg )
setRoute routeMaybe model =
    case routeMaybe of
        Nothing ->
            ( { model | pageState = Loaded Page.NotFound }, Cmd.none )

        Just Route.Home ->
            ( { model | pageState = Loaded Page.Home }, Cmd.none )

        Just (Route.Block hash) ->
            ( { model | pageState = Loaded (Page.Block hash) }
            , getBlock model hash
            )

        Just Route.Operations ->
            ( { model | pageState = Loaded Page.Operations }, Cmd.none )

        Just (Route.Operation operationId) ->
            ( { model | pageState = Loaded (Page.Operation operationId) }, Cmd.none )

        Just Route.Heads ->
            ( { model | pageState = Loaded Page.Heads }, Cmd.none )

        Just Route.Schema ->
            let
                schemaQuery1 =
                    "/describe"

                schemaQuery2 =
                    "/describe/blocks/head/proto"
            in
                ( { model | pageState = Loaded Page.Schema }
                , Cmd.batch
                    [ getSchema model.nodeUrl schemaQuery1 |> Http.send (LoadSchema schemaQuery1)
                    , getSchema model.nodeUrl schemaQuery2 |> Http.send (LoadSchema schemaQuery2)
                    ]
                )

        Just Route.Debug ->
            ( { model | pageState = Loaded Page.Debug }, Cmd.none )

        Just Route.Errors ->
            ( { model | pageState = Loaded Page.Errors }, Cmd.none )


loadHeads : Model -> Chain.BlocksData -> ( Model, Cmd Msg )
loadHeads model headsData =
    let
        newChain : Chain.Model
        newChain =
            Chain.loadHeads model.chain headsData

        showBranch : Maybe BlockID
        showBranch =
            List.head newChain.heads |> Debug.log "showBranch"
    in
        ( { model | chain = newChain }
        , showBranch |> Maybe.map (getBranch model) |> Maybe.withDefault Cmd.none
        )


loadBlocks : Model -> Chain.BlocksData -> ( Model, Cmd Msg )
loadBlocks model blocksData =
    let
        newChain =
            Chain.loadBlocks model.chain blocksData

        newModel =
            { model | chain = newChain }
    in
        ( newModel, getAllBlocksOperations newModel )


getBlock : Model -> BlockID -> Cmd Msg
getBlock model hash =
    case Dict.get hash model.chain.blocks of
        Nothing ->
            -- request block and some predecessors in anticipation of user following the chain
            Request.Block.getChainStartingAt model.nodeUrl 4 hash
                |> Http.send LoadBlocks

        _ ->
            Cmd.none


{-| Request chain starting at given block (hash) if necessary. If we already have some blocks stored, request only what is needed to get to some target length.
-}
getBranch : Model -> BlockID -> Cmd Msg
getBranch model blockhash =
    let
        branchList =
            Chain.getBranchList model.chain blockhash

        desiredLength =
            20

        toGet =
            desiredLength - List.length branchList
    in
        if toGet > 0 then
            let
                startHash =
                    List.reverse branchList
                        |> List.head
                        |> Maybe.map .predecessor
                        |> Maybe.withDefault blockhash
            in
                Request.Block.getChainStartingAt model.nodeUrl toGet startHash |> Http.send LoadBlocks
        else
            Cmd.none


getBlockOperationDetails : Model -> BlockID -> Cmd Msg
getBlockOperationDetails model blockHash =
    if Chain.blockNeedsOperations model.chain blockHash then
        Request.Operation.getBlockOperations model.nodeUrl blockHash
            |> Http.send (LoadBlockOperations blockHash)
    else
        Cmd.none


getAllBlocksOperations : Model -> Cmd Msg
getAllBlocksOperations model =
    let
        blocksToGet =
            Chain.blocksNeedingOperations model.chain |> Debug.log "blocksToGet"

        getBlockOperations blockHash =
            Request.Operation.getBlockOperations model.nodeUrl blockHash
                |> Http.send (LoadBlockOperations blockHash)
    in
        Cmd.batch (List.map getBlockOperations blocksToGet)
