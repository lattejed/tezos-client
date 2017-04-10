module Main exposing (main)

import Html as H exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Dict exposing (Dict)
import List.Extra as List
import ParseInt
import Schema exposing (..)


type alias Base58CheckEncodedSHA256 =
    String


type alias BlockID =
    Base58CheckEncodedSHA256


type alias OperationID =
    Base58CheckEncodedSHA256


type alias NetID =
    Base58CheckEncodedSHA256


type alias Fitness =
    String


type alias Timestamp =
    String


type alias Block =
    { hash : BlockID
    , predecessor : BlockID
    , fitness : List Fitness
    , timestamp :
        String
        -- TODO convert to date value
    , operations : List OperationID
    }


type alias BlocksData =
    List (List Block)


type RemoteData e a
    = NotAsked
    | Loading
    | Failure e
    | Success a


type alias Operation =
    { hash : OperationID
    , netID : NetID
    , data : String
    }


type alias Model =
    { blocks : List (List Block)
    , schemaData : Maybe SchemaData
    , errors : List Http.Error
    , nodeUrl : String
    , operations : RemoteData Http.Error (List Operation)
    , operation : RemoteData Http.Error Operation
    , showBlock : Maybe BlockID
    , showOperation : Maybe OperationID
    , showBranch : Maybe Int
    , levels : Dict BlockID Int
    , schemaQuery : String
    , parse : RemoteData Http.Error Decode.Value
    }


type Msg
    = LoadBlocks (Result Http.Error BlocksData)
    | LoadLevel BlockID (Result Http.Error Int)
    | LoadSchema (Result Http.Error SchemaData)
    | LoadOperations (Result Http.Error (List Operation))
    | LoadOperation (Result Http.Error Operation)
    | LoadParsedOperation (Result Http.Error Decode.Value)
    | SchemaMsg Schema.Msg
    | ShowBlock BlockID
    | ShowOperation OperationID
    | ShowBranch Int


main =
    H.programWithFlags
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


{-| Construct an RPC request for the blockchain header data.
-}
getBlocks : String -> Http.Request BlocksData
getBlocks nodeUrl =
    let
        maxBlocksToGet =
            100

        body =
            [ ( "operations", Encode.bool True )
            , ( "length", Encode.int maxBlocksToGet )
            ]
                |> Encode.object
                |> Http.jsonBody

        url =
            nodeUrl ++ "/blocks"
    in
        Http.post url body decodeBlocks


decodeBlocks : Decode.Decoder BlocksData
decodeBlocks =
    Decode.field "blocks" (Decode.list (Decode.list decodeBlock))


decodeBlock : Decode.Decoder Block
decodeBlock =
    Decode.map5 Block
        (Decode.field "hash" Decode.string)
        (Decode.field "predecessor" Decode.string)
        (Decode.field "fitness" (Decode.list Decode.string))
        (Decode.field "timestamp" decodeTimestamp)
        (Decode.field "operations" (Decode.list Decode.string))


decodeTimestamp : Decode.Decoder Timestamp
decodeTimestamp =
    -- TODO
    Decode.string


getOperations : String -> Http.Request (List Operation)
getOperations nodeUrl =
    let
        body =
            [ ( "contents", Encode.bool True ) ] |> Encode.object |> Http.jsonBody
    in
        Http.post (nodeUrl ++ "/operations") body decodeOperations


getOperation : String -> OperationID -> Http.Request Operation
getOperation nodeUrl operationId =
    let
        body =
            [] |> Encode.object |> Http.jsonBody

        setHash hash operation =
            { operation | hash = hash }

        decoder : Decode.Decoder Operation
        decoder =
            decodeOperationContents |> Decode.map (setHash operationId)
    in
        Http.post (nodeUrl ++ "/operations/" ++ operationId) body decoder


decodeOperations : Decode.Decoder (List Operation)
decodeOperations =
    Decode.field "operations" (Decode.list decodeOperation)


decodeOperation : Decode.Decoder Operation
decodeOperation =
    Decode.map3 Operation
        (Decode.field "hash" Decode.string)
        (Decode.at [ "contents", "net_id" ] Decode.string)
        (Decode.at [ "contents", "data" ] Decode.string)


decodeOperationContents : Decode.Decoder Operation
decodeOperationContents =
    Decode.map3 Operation
        (Decode.succeed "bogus")
        (Decode.field "net_id" Decode.string)
        (Decode.field "data" Decode.string)


getSchema : String -> String -> Http.Request SchemaData
getSchema nodeUrl schemaQuery =
    let
        body =
            [ ( "recursive", Encode.bool True ) ] |> Encode.object |> Http.jsonBody

        url =
            nodeUrl ++ schemaQuery
    in
        Http.post url body decodeSchema


getLevelCommand : String -> BlockID -> Cmd Msg
getLevelCommand nodeUrl blockid =
    let
        url =
            nodeUrl ++ "/blocks/" ++ blockid ++ "/proto/context/level"

        body =
            Encode.object [] |> Http.jsonBody

        request : Http.Request Int
        request =
            Http.post url body decodeLevel
    in
        Http.send (LoadLevel blockid) request


getLevelCommands : String -> List (List Block) -> Cmd Msg
getLevelCommands nodeUrl branches =
    List.filterMap getHeadId branches
        |> List.map (getLevelCommand nodeUrl)
        |> Cmd.batch


getHeadId : List Block -> Maybe BlockID
getHeadId blocks =
    List.head blocks |> Maybe.map .hash


decodeLevel : Decode.Decoder Int
decodeLevel =
    Decode.at [ "ok", "level" ] Decode.int


getParseOperationCommand : String -> Operation -> Cmd Msg
getParseOperationCommand nodeUrl operation =
    let
        url =
            nodeUrl ++ "/blocks/head/proto/helpers/parse/operation"

        body =
            [ ( "data", Encode.string operation.data )
            , ( "net_id", Encode.string operation.netID )
            ]
                |> Encode.object
                |> Http.jsonBody
    in
        Http.post url body Decode.value |> Http.send LoadParsedOperation


type alias Flags =
    { nodeUrl : String }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        model =
            { blocks = []
            , schemaData = Nothing
            , errors = []
            , nodeUrl = flags.nodeUrl
            , operations = NotAsked
            , operation = NotAsked
            , showBlock = Nothing
            , showOperation = Nothing
            , showBranch = Nothing
            , levels =
                Dict.empty
            , schemaQuery = "/describe/blocks/head/proto"
            , parse = NotAsked
            }
    in
        ( model
        , Cmd.batch
            [ Http.send LoadBlocks (getBlocks model.nodeUrl)
            , Http.send LoadSchema (getSchema model.nodeUrl model.schemaQuery)
              --, Http.send LoadOperations (getOperations model.nodeUrl)
            ]
        )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg |> Debug.log "msg" of
        LoadBlocks blocksMaybe ->
            case blocksMaybe of
                Ok blocks ->
                    ( { model | blocks = blocks }
                    , getLevelCommands model.nodeUrl blocks
                    )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        LoadLevel blockid result ->
            case result of
                Ok level ->
                    let
                        newLevels =
                            Dict.insert blockid level model.levels
                    in
                        ( { model | levels = newLevels }, Cmd.none )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        LoadSchema schemaMaybe ->
            case schemaMaybe of
                Ok schemaData ->
                    ( { model | schemaData = Just (collapseTrees schemaData) }, Cmd.none )

                Err error ->
                    ( { model | errors = error :: model.errors }, Cmd.none )

        SchemaMsg msg ->
            let
                newSchema =
                    Schema.update msg model.schemaData
            in
                ( { model | schemaData = newSchema }, Cmd.none )

        LoadOperations operationsResult ->
            case operationsResult of
                Ok operationsData ->
                    ( { model | operations = Success operationsData }, Cmd.none )

                Err error ->
                    ( { model | operations = Failure error }, Cmd.none )

        LoadOperation operationResult ->
            case operationResult of
                Ok operation ->
                    ( { model | operation = Success operation }
                    , getParseOperationCommand model.nodeUrl operation
                    )

                Err error ->
                    ( { model | operation = Failure error }, Cmd.none )

        LoadParsedOperation parseResult ->
            case parseResult of
                Ok parse ->
                    ( { model | parse = Success parse }, Cmd.none )

                Err error ->
                    ( { model | parse = Failure error }, Cmd.none )

        ShowBlock blockhash ->
            ( { model | showBlock = Just blockhash }, Cmd.none )

        ShowOperation operationhash ->
            ( { model | showOperation = Just operationhash }
            , Http.send LoadOperation (getOperation model.nodeUrl operationhash)
            )

        ShowBranch index ->
            ( { model | showBranch = Just index }, Cmd.none )


view : Model -> Html Msg
view model =
    H.div []
        [ viewHeader model.nodeUrl
        , viewError model.nodeUrl model.errors
        , viewHeads model.blocks model.levels
        , viewShowBranch model.blocks model.showBranch
        , viewShowBlock model.blocks model.showBlock
        , viewShowOperation model.operation model.showOperation
        , viewParse model.parse
        , viewOperations model.operations
        , case model.schemaData of
            Just schemaData ->
                viewSchemaDataTop model.schemaQuery schemaData |> H.map SchemaMsg

            Nothing ->
                H.text ""
          --, viewSchemaDataRaw model.schemaData |> H.map SchemaMsg
          --     , viewDebug model
        ]


viewHeader : String -> Html Msg
viewHeader nodeUrl =
    H.div []
        [ H.h1 [] [ H.text "Tezos client" ]
        , H.div [] [ H.text ("Connecting to Tezos RPC server " ++ nodeUrl) ]
        ]


canonFitness : List String -> List Int
canonFitness strings =
    List.map (ParseInt.parseIntHex >> Result.withDefault 0) strings
        |> List.dropWhile ((==) 0)


viewHeads : List (List Block) -> Dict BlockID Int -> Html Msg
viewHeads branches levels =
    let
        header =
            H.tr []
                [ H.th [] [ H.text "index" ]
                , H.th [] [ H.text "hash" ]
                , H.th [] [ H.text "timestamp" ]
                , H.th [] [ H.text "fitness" ]
                , H.th [] [ H.text "level" ]
                ]

        viewBlockSummary : Int -> Block -> Html Msg
        viewBlockSummary i block =
            H.tr [ HA.class "head" ]
                [ H.td [] [ H.text (toString i) ]
                , H.td
                    [ HA.class "hash"
                    , HE.onClick (ShowBranch i)
                    ]
                    [ H.text block.hash ]
                , H.td [] [ H.text block.timestamp ]
                , H.td [] [ H.text (toString (canonFitness block.fitness)) ]
                , H.td []
                    [ Dict.get block.hash levels
                        |> Maybe.map toString
                        |> Maybe.withDefault ""
                        |> H.text
                    ]
                ]

        viewHead : Int -> List Block -> Html Msg
        viewHead i blocks =
            case blocks of
                head :: _ ->
                    viewBlockSummary i head

                _ ->
                    H.text ""
    in
        H.div []
            [ H.h2 [] [ H.text "Blockchain heads" ]
            , H.table [ HA.class "heads" ]
                [ H.thead [] [ header ]
                , H.tbody [] (List.indexedMap viewHead branches)
                ]
            ]


findBranchByHead : List (List Block) -> BlockID -> Maybe (List Block)
findBranchByHead branches headid =
    let
        match branch =
            case branch of
                head :: tail ->
                    head.hash == headid

                _ ->
                    False
    in
        List.find match branches


viewShowBranch : List (List Block) -> Maybe Int -> Html Msg
viewShowBranch branches indexMaybe =
    let
        index =
            Maybe.withDefault 0 indexMaybe

        branchMaybe =
            List.getAt index branches
    in
        Maybe.map (viewBranch index) branchMaybe |> Maybe.withDefault (H.text "")


viewBranch n branch =
    let
        tableHeader =
            H.tr []
                [ H.th [ HA.class "hash" ] [ H.text "hash" ]
                , H.th [ HA.class "timestamp" ] [ H.text "timestamp" ]
                , H.th [ HA.class "operations" ] [ H.text "operations" ]
                ]
    in
        H.div [ HA.class "branch" ]
            [ H.h3 [] [ H.text ("branch " ++ toString n) ]
            , H.table [ HA.class "blockchain" ]
                [ H.thead [] [ tableHeader ]
                , H.tbody [] (List.indexedMap viewBlock2 branch)
                ]
            ]


viewBlock2 : Int -> Block -> Html Msg
viewBlock2 n block =
    H.tr [ HA.class "block" ]
        [ H.td
            [ HA.class "hash"
            , HA.title "click to view block details"
            , HE.onClick (ShowBlock block.hash)
            ]
            [ H.text block.hash ]
        , H.td [ HA.class "timestamp" ] [ H.text block.timestamp ]
        , H.td [ HA.class "operations" ] [ H.text <| toString <| List.length block.operations ]
        ]


viewBlocks : List (List Block) -> Html Msg
viewBlocks branches =
    let
        header =
            [ H.h2 [] [ H.text "Block chains" ] ]
    in
        H.div [ HA.class "branches" ] (header ++ List.indexedMap viewBranch branches)


{-| View details of a single block.
-}
viewBlock : Block -> Html Msg
viewBlock block =
    let
        viewProperty : String -> Html Msg -> Html Msg
        viewProperty label value =
            H.div [ HA.class "property" ]
                [ H.div [ HA.class "label" ] [ H.text label ]
                , H.div [] [ value ]
                ]

        viewPropertyString : String -> String -> Html Msg
        viewPropertyString label value =
            viewProperty label (H.text value)

        viewPropertyList : String -> List String -> Html Msg
        viewPropertyList label values =
            viewProperty label (List.intersperse ", " values |> String.concat |> H.text)

        viewPropertyList2 : String -> List String -> Html Msg
        viewPropertyList2 label values =
            let
                li value =
                    H.li [ HE.onClick (ShowOperation value), HA.class "operation" ] [ H.text value ]
            in
                H.ol [] (List.map li values) |> viewProperty label
    in
        H.div [ HA.class "block" ]
            [ H.h3 [] [ H.text "Block" ]
            , H.div [ HA.class "property-list" ]
                [ viewPropertyString "hash" block.hash
                , viewPropertyString "predecessor" block.predecessor
                , viewPropertyString "timestamp" block.timestamp
                , viewPropertyList "fitness" block.fitness
                , viewPropertyList2 "operations" block.operations
                ]
            ]


viewShowBlock : List (List Block) -> Maybe BlockID -> Html Msg
viewShowBlock blocks blockhashMaybe =
    case blockhashMaybe of
        Just blockhash ->
            case findBlock blocks blockhash of
                Just block ->
                    viewBlock block

                Nothing ->
                    H.div [] [ H.text ("Cannot find block " ++ blockhash) ]

        Nothing ->
            H.text ""


findInChain : List Block -> BlockID -> Maybe Block
findInChain blocks hash =
    List.find (\block -> block.hash == hash) blocks


findBlock : List (List Block) -> BlockID -> Maybe Block
findBlock blockchains hash =
    case blockchains of
        [] ->
            Nothing

        hd :: tl ->
            case findInChain hd hash of
                Just block ->
                    Just block

                Nothing ->
                    findBlock tl hash


findOperation : List Operation -> OperationID -> Maybe Operation
findOperation operations operationId =
    List.find (\operation -> operation.hash == operationId) operations


viewShowOperation : RemoteData error Operation -> Maybe OperationID -> Html Msg
viewShowOperation operationData operationidMaybe =
    case operationidMaybe of
        Just operationId ->
            case operationData of
                Success operation ->
                    viewOperation operation

                _ ->
                    H.text (toString operationData)

        Nothing ->
            H.text ""


viewOperations : RemoteData Http.Error (List Operation) -> Html Msg
viewOperations operationsStatus =
    H.div []
        [ H.h2 [] [ H.text "Operations" ]
        , case operationsStatus of
            Success operations ->
                H.div [ HA.class "property-list" ] (List.map viewOperation operations)

            Failure error ->
                H.div [] [ H.text ("Error: " ++ toString operationsStatus) ]

            _ ->
                H.div [] [ H.text (toString operationsStatus) ]
        ]


shortHash hash =
    String.left 8 hash


viewOperation : Operation -> Html Msg
viewOperation operation =
    let
        id =
            "operationdata-" ++ operation.hash
    in
        H.div []
            [ H.h4 [] [ H.text ("Operation " ++ operation.hash) ]
            , H.div [ HA.class "property" ]
                [ H.div [ HA.class "label" ] [ H.text "data" ]
                , H.div [ HA.class "operation-data" ] [ H.text operation.data ]
                ]
            ]


viewError : String -> List Http.Error -> Html Msg
viewError nodeUrl errors =
    case errors of
        [] ->
            H.text ""

        errors ->
            H.div [ HA.class "error" ]
                [ H.h1 [] [ H.text "Error" ]
                , H.div [] (List.map (viewErrorInfo nodeUrl) errors)
                ]


viewErrorInfo nodeUrl error =
    case error of
        Http.BadPayload message response ->
            H.div []
                [ H.h2 [] [ H.text "Bad Payload (JSON parsing problem)" ]
                , H.div [ HA.style [ ( "white-space", "pre" ) ] ] [ H.text message ]
                ]

        Http.BadStatus response ->
            H.div []
                [ H.h2 [] [ H.text "Bad response status from node" ]
                , H.div [] [ H.text (toString response.status) ]
                , H.div [] [ H.text response.url ]
                  --, H.div [ HA.style [ ( "white-space", "pre" ) ] ] [ H.text (toString response) ]
                ]

        Http.NetworkError ->
            H.div []
                [ H.h2 [] [ H.text "Network Error" ]
                , H.div [] [ H.text ("Unable to access Tezos node at " ++ nodeUrl) ]
                ]

        _ ->
            H.text (toString error)


viewDebug : Model -> Html Msg
viewDebug model =
    H.div [ HA.class "debug" ]
        [ H.h2 [] [ H.text "Raw model" ]
        , H.text <| toString model
        ]


viewParse : RemoteData Http.Error Decode.Value -> Html Msg
viewParse parseData =
    H.div []
        [ H.h2 [] [ H.text "Parsed operation" ]
        , H.text (toString parseData)
        ]


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.none