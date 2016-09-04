{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
module Gelatin.FreeType2.Internal where
import           Gelatin.GL
import           Gelatin.FreeType2.Utils
import           Gelatin.Picture.Internal
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.State.Strict
import           Data.Maybe (fromMaybe)
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import           Data.Map (Map)
import qualified Data.Map as M
import           Graphics.Rendering.FreeType.Internal.GlyphMetrics as GM
import           Graphics.Rendering.FreeType.Internal.Bitmap as BM
--------------------------------------------------------------------------------
-- WordMap
--------------------------------------------------------------------------------
type WordMap = Map String (V2 Float, GLRenderer)

loadWords :: MonadIO m
          => Rez -> Atlas -> String -> m Atlas
loadWords rz atlas str = do
  wm <- liftIO $ foldM loadWord (atlasWordMap atlas) $ words str
  return atlas{atlasWordMap=wm}
  where loadWord wm word
          | Just _ <- M.lookup word wm = return wm
          | otherwise = do
            let pic = do freetypePicture atlas red word
                         pictureSize
            (sz,dat) <- runPictureT pic
            r  <- compileTexturePictureData rz dat
            return $ M.insert word (sz,r) wm

unloadMissingWords :: MonadIO m => Atlas -> String -> m Atlas
unloadMissingWords atlas str = do
  let wm = atlasWordMap atlas
      ws = M.fromList $ zip (words str) [(0::Int)..]
      missing = M.difference wm ws
      retain  = M.difference wm missing
      dealoc  = (liftIO . fst . snd) <$> missing
  sequence_ dealoc
  return atlas{atlasWordMap=retain}
--------------------------------------------------------------------------------
-- Glyph
--------------------------------------------------------------------------------
data GlyphSize = CharSize Float Float Int Int
               | PixelSize Int Int
               deriving (Show, Eq)

glyphWidth :: GlyphSize -> Float
glyphWidth (CharSize x y _ _) = if x == 0 then y else x
glyphWidth (PixelSize x y) = fromIntegral $ if x == 0 then y else x

glyphHeight :: GlyphSize -> Float
glyphHeight (CharSize x y _ _) = if y == 0 then x else y
glyphHeight (PixelSize x y) = fromIntegral $ if y == 0 then x else y

-- https://www.freetype.org/freetype2/docs/tutorial/step2.html
data GlyphMetrics = GlyphMetrics { glyphTexBB       :: (V2 Int, V2 Int)
                                 , glyphTexSize     :: V2 Int
                                 , glyphSize        :: V2 Int
                                 , glyphHoriBearing :: V2 Int
                                 , glyphVertBearing :: V2 Int
                                 , glyphAdvance     :: V2 Int
                                 } deriving (Show, Eq)
--------------------------------------------------------------------------------
-- Atlas
--------------------------------------------------------------------------------
data Atlas = Atlas { atlasTexture     :: GLuint
                   , atlasTextureSize :: V2 Int
                   , atlasLibrary     :: FT_Library
                   , atlasFontFace    :: FT_Face
                   , atlasMetrics     :: IntMap GlyphMetrics
                   , atlasGlyphSize   :: GlyphSize
                   , atlasWordMap     :: WordMap
                   }

emptyAtlas :: FT_Library -> FT_Face -> GLuint -> Atlas
emptyAtlas lib face t = Atlas t 0 lib face mempty (PixelSize 0 0) mempty

data AtlasMeasure = AM { amWH :: V2 Int
                       , amXY :: V2 Int
                       , rowHeight :: Int
                       , amMap :: IntMap (V2 Int)
                       } deriving (Show, Eq)

emptyAM :: AtlasMeasure
emptyAM = AM 0 (V2 1 1) 0 mempty

spacing :: Int
spacing = 1

measure :: FT_Face -> Int -> AtlasMeasure -> Char -> FreeTypeIO AtlasMeasure
measure face maxw am@AM{..} char
  | Just _ <- IM.lookup (fromEnum char) amMap = return am
  | otherwise = do
    let V2 x y = amXY
        V2 w h = amWH
    -- Load the char, replacing the glyph according to
    -- https://www.freetype.org/freetype2/docs/tutorial/step1.html
    loadChar face (fromIntegral $ fromEnum char) ft_LOAD_RENDER
    -- Get the glyph slot
    slot <- liftIO $ peek $ glyph face
    -- Get the bitmap
    bmp   <- liftIO $ peek $ bitmap slot
    let bw = fromIntegral $ BM.width bmp
        bh = fromIntegral $ rows bmp
        gotoNextRow = (x + bw + spacing) >= maxw
        rh = if gotoNextRow then 0 else max bh rowHeight
        nx = if gotoNextRow then 0 else x + bw + spacing
        nw = max w (x + bw + spacing)
        nh = max h (y + rh + spacing)
        ny = if gotoNextRow then nh else y
        am = AM { amWH = V2 nw nh
                , amXY = V2 nx ny
                , rowHeight = rh
                , amMap = IM.insert (fromEnum char) amXY amMap
                }
    return am

texturize :: IntMap (V2 Int) -> Atlas -> Char -> FreeTypeIO Atlas
texturize xymap atlas@Atlas{..} char
  | Just pos@(V2 x y) <- IM.lookup (fromEnum char) xymap = do
    -- Load the char
    loadChar atlasFontFace (fromIntegral $ fromEnum char) ft_LOAD_RENDER
    -- Get the slot and bitmap
    slot  <- liftIO $ peek $ glyph atlasFontFace
    bmp   <- liftIO $ peek $ bitmap slot
    -- Update our texture by adding the bitmap
    glTexSubImage2D GL_TEXTURE_2D 0
                    (fromIntegral x) (fromIntegral y)
                    (fromIntegral $ BM.width bmp) (fromIntegral $ rows bmp)
                    GL_RED GL_UNSIGNED_BYTE
                    (castPtr $ buffer bmp)
    -- Get the glyph metrics
    ftms  <- liftIO $ peek $ metrics slot
    -- Add the metrics to the atlas
    let vecwh = fromIntegral <$> V2 (BM.width bmp) (rows bmp)
        canon = floor . (/64) . realToFrac . fromIntegral
        vecsz = canon <$> V2 (GM.width ftms) (GM.height ftms)
        vecxb = canon <$> V2 (horiBearingX ftms) (horiBearingY ftms)
        vecyb = canon <$> V2 (vertBearingX ftms) (vertBearingY ftms)
        vecad = canon <$> V2 (horiAdvance ftms) (vertAdvance ftms)
        mtrcs = GlyphMetrics { glyphTexBB = (pos, pos + vecwh)
                             , glyphTexSize = vecwh
                             , glyphSize = vecsz
                             , glyphHoriBearing = vecxb
                             , glyphVertBearing = vecyb
                             , glyphAdvance = vecad
                             }
    return atlas{ atlasMetrics = IM.insert (fromEnum char) mtrcs atlasMetrics }

  | otherwise = do
    liftIO $ putStrLn "could not find xy"
    return atlas

allocAtlas :: MonadIO m
           => FilePath -> GlyphSize -> String -> m (Maybe Atlas)
allocAtlas fontFilePath gs str = do
  e <- liftIO $ runFreeType $ do
    fce <- newFace fontFilePath
    case gs of
      PixelSize w h -> setPixelSizes fce w h
      CharSize w h dpix dpiy -> setCharSize fce (floor $ 26.6 * w)
                                                (floor $ 26.6 * h)
                                                dpix dpiy

    AM{..} <- foldM (measure fce 512) emptyAM str

    let V2 w h = amWH
        xymap  = amMap

    t <- liftIO $ do
      t <- allocAndActivateTex GL_TEXTURE0
      glPixelStorei GL_UNPACK_ALIGNMENT 1
      withCString (replicate (w * h) $ toEnum 0) $
        glTexImage2D GL_TEXTURE_2D 0 GL_RED (fromIntegral w) (fromIntegral h)
                     0 GL_RED GL_UNSIGNED_BYTE . castPtr
      return t

    lib   <- getLibrary
    atlas <- foldM (texturize xymap) (emptyAtlas lib fce t) str

    glGenerateMipmap GL_TEXTURE_2D
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S GL_REPEAT
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T GL_REPEAT
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_LINEAR
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_LINEAR
    glBindTexture GL_TEXTURE_2D 0
    glPixelStorei GL_UNPACK_ALIGNMENT 4
    return
      atlas{ atlasTextureSize = V2 w h
           , atlasGlyphSize = gs
           }
  case e of
    Left err -> liftIO (print err) >> return Nothing
    Right (atlas,_) -> return $ Just atlas

freeAtlas :: MonadIO m => Atlas -> m ()
freeAtlas a = do
  _ <- liftIO $ ft_Done_FreeType (atlasLibrary a)
  _ <- liftIO $ unloadMissingWords a ""
  return ()

withAtlas :: MonadIO m => FilePath -> GlyphSize -> String -> (Atlas -> m a) -> m (Maybe a)
withAtlas fontFilePath gs str f = allocAtlas fontFilePath gs str >>= \case
  Nothing    -> return Nothing
  Just atlas -> do a <- f atlas
                   freeAtlas atlas
                   return $ Just a

makeCharQuad :: MonadIO m => Atlas -> Bool -> (Int, Maybe FT_UInt) -> Char
             -> VerticesT (V2 Float, V2 Float) m (Int, Maybe FT_UInt)
makeCharQuad Atlas{..} useKerning (penx, mLast) char = do
  let ichar = fromEnum char
  eNdx <- withFreeType (Just atlasLibrary) $ getCharIndex atlasFontFace ichar
  let mndx = either (const Nothing) Just eNdx
  px <- case (,,) <$> mndx <*> mLast <*> Just useKerning of
    Just (ndx,lndx,True) -> do
      e <- withFreeType (Just atlasLibrary) $
        getKerning atlasFontFace lndx ndx ft_KERNING_DEFAULT
      return $ either (const penx) ((+penx) . floor . (/(64::Double)) . fromIntegral . fst) e
    _  -> return $ fromIntegral penx
  case IM.lookup ichar atlasMetrics of
    Nothing -> return (penx, mndx)
    Just GlyphMetrics{..} -> do
      let V2 dx dy = fromIntegral <$> glyphHoriBearing
          x = (fromIntegral px) + dx
          y = -dy
          V2 w h = fromIntegral <$> glyphSize
          V2 aszW aszH = fromIntegral <$> atlasTextureSize
          V2 texL texT = fromIntegral <$> fst glyphTexBB
          V2 texR texB = fromIntegral <$> snd glyphTexBB

          -- TODO: Add kerning
          tl = (V2 (x)    y   , V2 (texL/aszW) (texT/aszH))
          tr = (V2 (x+w)  y   , V2 (texR/aszW) (texT/aszH))
          br = (V2 (x+w) (y+h), V2 (texR/aszW) (texB/aszH))
          bl = (V2 (x)   (y+h), V2 (texL/aszW) (texB/aszH))
      tri tl tr br
      tri tl br bl
      let V2 ax _ = glyphAdvance

      return (px + ax, mndx)

asciiChars :: String
asciiChars = map toEnum [32..126]

stringTris :: MonadIO m => Atlas -> Bool -> String -> VerticesT (V2 Float, V2 Float) m ()
stringTris atlas useKerning =
  foldM_ (makeCharQuad atlas useKerning) (0, Nothing)
--------------------------------------------------------------------------------
-- Picture
--------------------------------------------------------------------------------
-- | Constructs a @PictureT GLuint (V2 Float) (V2 Float, V2 Float) m ()@
-- in all red. Colorization can then be done using @setReplacementColor@
freetypePictureNoColor :: MonadIO m => Atlas -> String -> TexturePictureT m ()
freetypePictureNoColor atlas@Atlas{..} str = do
  eKerning <- withFreeType (Just atlasLibrary) $ hasKerning atlasFontFace
  setTextures [atlasTexture]
  let useKerning = either (const False) id eKerning
  setGeometry $ triangles $ stringTris atlas useKerning str
-- | Constructs a @PictureT GLuint (V2 Float) (V2 Float, V2 Float) m ()@ using
-- the given colored string.
freetypePicture :: MonadIO m
                => Atlas -> V4 Float -> String -> TexturePictureT m ()
freetypePicture atlas color str = do
  freetypePictureNoColor atlas str
  setReplacementColor color
--------------------------------------------------------------------------------
-- Performance Rendering
--------------------------------------------------------------------------------
-- | Constructs a @GLRenderer@ from the given colored string. Skipping the step
-- given by @freetypePicture@ allows the atlas' WordMap to be used to construct
-- the string, which greatly improves performance, allowing longer strings to be
-- compiled and renderered in real time.
-- Note that since resources are stored in the atlas' WordMap the returned
-- renderer contains a clean up operation that does nothing. It is expected that
-- you manage the resources manually through the atlas.
freetypeGLRenderer :: MonadIO m
                   => Rez -> Atlas -> V4 Float -> String
                   -> m (GLRenderer, V2 Float, Atlas)
freetypeGLRenderer rz atlas0 color str = do
  atlas <- loadWords rz atlas0 str
  let glyphw  = glyphWidth $ atlasGlyphSize atlas
      spacew  = fromMaybe glyphw $ do
        metrics <- IM.lookup (fromEnum ' ') $ atlasMetrics atlas
        let V2 x _ = glyphAdvance metrics
        return $ fromIntegral x
      glyphh = glyphHeight $ atlasGlyphSize atlas
      renderWord :: PictureTransform -> Float -> String -> IO ()
      renderWord _ _ ""       = return ()
      renderWord t x (' ':cs) = renderWord t (x + spacew) cs
      renderWord t x cs       = do
        let word = takeWhile (/= ' ') cs
            rest = drop (length word) cs
        case M.lookup word (atlasWordMap atlas) of
          Nothing          -> renderWord t x rest
          Just (V2 w _, r) -> do
            let tt = mempty
                       {ptfrmMV = affineToModelview $ Translate $ V2 x 0
                       ,ptfrmReplace = Just color
                       }
            snd r $ t `mappend` tt
            renderWord t (x + w) rest
      rr t = renderWord t 0 str
      measureWord x ""       = x
      measureWord x (' ':cs) = measureWord (x + spacew) cs
      measureWord x cs       =
        let word = takeWhile (/= ' ') cs
            rest = drop (length word) cs
            n    = case M.lookup word (atlasWordMap atlas) of
                     Nothing          -> x
                     Just (V2 w _, _) -> x + w
        in measureWord n rest
      ww = measureWord 0 str
  return ((return (), rr), V2 ww glyphh, atlas)
