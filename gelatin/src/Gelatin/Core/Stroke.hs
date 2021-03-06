{-# LANGUAGE DeriveGeneric #-}
-- | Strokes are used for defining lines and drawing them.
module Gelatin.Core.Stroke where

import           Data.Maybe   (fromMaybe)
import           GHC.Generics (Generic)

data LineCap = LineCapNone
             | LineCapButt
             | LineCapSquare
             | LineCapRound
             | LineCapTriOut
             | LineCapTriIn
             deriving (Show, Ord, Eq, Enum, Generic)

data Stroke = Stroke { strokeWidth    :: Float
                     , strokeFeather  :: Float
                     , strokeLineCaps :: (LineCap,LineCap)
                     } deriving (Show, Eq, Generic)

data StrokeAttr = StrokeNone
                | StrokeWidth Float
                | StrokeFeather Float
                | StrokeCaps (LineCap,LineCap)
                deriving (Show, Eq, Generic)

defaultStroke :: Stroke
defaultStroke = Stroke 1 1 (LineCapRound,LineCapRound)

strokeAttr :: Maybe Stroke -> StrokeAttr -> Maybe Stroke
strokeAttr _ StrokeNone               = Nothing
strokeAttr Nothing c                  = strokeAttr (Just defaultStroke) c
strokeAttr (Just s) (StrokeWidth w)   = Just $ s {strokeWidth = w}
strokeAttr (Just s) (StrokeFeather t) = Just $ s {strokeFeather = t}
strokeAttr (Just s) (StrokeCaps cs)   = Just $ s {strokeLineCaps = cs}

strokeWith :: [StrokeAttr] -> Stroke
strokeWith atts = fromMaybe defaultStroke $ foldl strokeAttr Nothing atts
