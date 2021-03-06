{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- | Limited spatial transformations in 2 and 3 dimensions.
module Gelatin.Core.Transform where

import           Data.Foldable (foldl')
import           Linear        (Epsilon (..), M44, V1 (..), V2 (..),
                                V3 (..), V4 (..), axisAngle, identity,
                                mkTransformation, mkTransformationMat, (!*!))
--------------------------------------------------------------------------------
-- Affine Transformation
--------------------------------------------------------------------------------
data Affine a r = Translate a
                | Scale a
                | Rotate r
                deriving (Show, Eq)

type Affine2 a = Affine (V2 a) a

type Affine3 a = Affine (V3 a) (a, V3 a)

-- | Promotes a point in R2 to a point in R3 by setting the z coord to '0'.
promoteV2 :: Num a => V2 a -> V3 a
promoteV2 (V2 x y) = V3 x y 0

-- | Demotes a point in R3 to a point in R2 by discarding the z coord.
demoteV3 :: V3 a -> V2 a
demoteV3 (V3 x y _) = V2 x y

-- | Promotes an affine transformation in R2 to one in R3 by using `promoteV2`
-- in case of translation or scaling, and promotes rotation as a rotation about
-- the z axis.
promoteAffine2 :: Num a => Affine2 a -> Affine3 a
promoteAffine2 (Translate v2) = Translate $ promoteV2 v2
promoteAffine2 (Scale v2)     = Scale $ promoteV2 v2
promoteAffine2 (Rotate r)     = Rotate (r, V3 0 0 1)

affine3Modelview :: (Num a, Real a, Floating a, Epsilon a)
                 => Affine3 a -> M44 a
affine3Modelview (Translate v)     = mat4Translate v
affine3Modelview (Scale v)         = mat4Scale v
affine3Modelview (Rotate (r,axis)) = mat4Rotate r axis

affine2Modelview :: (Num a, Real a, Floating a, Epsilon a)
                 => Affine2 a -> M44 a
affine2Modelview = affine3Modelview . promoteAffine2

affine2sModelview :: (Num a, Real a, Floating a, Epsilon a)
                => [Affine2 a] -> M44 a
affine2sModelview = foldl' f identity
    where f mv a = (mv !*!) $ affine2Modelview a

transformV2 :: Num a => M44 a -> V2 a ->  V2 a
transformV2 mv = demoteV3 . m41ToV3 . (mv !*!) . v3ToM41 . promoteV2

transformPoly :: M44 Float -> [V2 Float] -> [V2 Float]
transformPoly t = map (transformV2 t)

transformV3 :: RealFloat a => M44 a -> V3 a -> V3 a
transformV3 t v = m41ToV3 $ t !*! v3ToM41 v

v3ToM41 :: Num a => V3 a -> V4 (V1 a)
v3ToM41 (V3 x y z) = V4 (V1 x) (V1 y) (V1 z) (V1 1)

m41ToV3 :: V4 (V1 a) -> V3 a
m41ToV3 (V4 (V1 x) (V1 y) (V1 z) _) = V3 x y z

rotateAbout :: (Num a, Epsilon a, Floating a) => V3 a -> a -> V3 a -> V3 a
rotateAbout axis phi = m41ToV3 . (mat4Rotate phi axis !*!) . v3ToM41
--------------------------------------------------------------------------------
-- Matrix helpers
--------------------------------------------------------------------------------
mat4Translate :: Num a => V3 a -> M44 a
mat4Translate = mkTransformationMat identity

mat4Rotate :: (Num a, Epsilon a, Floating a) => a -> V3 a -> M44 a
mat4Rotate phi v = mkTransformation (axisAngle v phi) (V3 0 0 0)

mat4Scale :: Num a => V3 a -> M44 a
mat4Scale (V3 x y z) =
    V4 (V4 x 0 0 0)
       (V4 0 y 0 0)
       (V4 0 0 z 0)
       (V4 0 0 0 1)
