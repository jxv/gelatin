{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Gelatin.Core.Render (
    module R,
    module GLFW,
    initWindow,
    --enableBlending,
    --getRenderer,
    --render,
    --rendering,
    --renderToTexture,
    --cache,
    loadGeomRenderSource,
    loadBezRenderSource,
    loadRenderSource,
    loadTexture,
    colorRenderer,
    colorBezRenderer,
    colorFontRenderer,
    textureRenderer,
    stencilXOR,
    toTexture,
    calculateDpi,
    compileFontCache
    --drawClear,
    --withNewFrame,
    --gets
) where

import Gelatin.Core.Shader
import Gelatin.Core.Render.Types as R
import Gelatin.Core.Render.Geometrical as R
import Gelatin.Core.Render.Font as R
import Graphics.GL.Core33
import Graphics.UI.GLFW as GLFW
import Foreign.Marshal.Array
import Foreign.Marshal.Utils
import Foreign.C.String
import Foreign.Storable
import Foreign.Ptr
import Data.Monoid
import Data.Maybe
import Data.Vector.Storable (Vector,unsafeWith)
import Control.Applicative
import Control.Concurrent.Async
import Control.Monad
import System.Directory
import System.IO
import System.Exit
import qualified Data.ByteString.Char8 as B
import qualified Data.Foldable as F

-- | Starts up the app by creating a window and returning some default
-- values for resources.
initWindow :: Int -> Int -> String -> IO Window
initWindow ww wh ws = do
    setErrorCallback $ Just $ \_ -> hPutStrLn stderr
    True <- GLFW.init
    defaultWindowHints
    windowHint $ WindowHint'OpenGLDebugContext True
    windowHint $ WindowHint'OpenGLProfile OpenGLProfile'Core
    windowHint $ WindowHint'OpenGLForwardCompat True
    windowHint $ WindowHint'ContextVersionMajor 3
    windowHint $ WindowHint'ContextVersionMinor 2
    windowHint $ WindowHint'DepthBits 16
    mwin <- createWindow ww wh ws Nothing Nothing
    makeContextCurrent mwin
    window <- case mwin of
                  Nothing  -> do putStrLn "could not create window"
                                 exitFailure
                  Just win -> return win
    return window

--------------------------------------------------------------------------------
-- Renderers
--------------------------------------------------------------------------------

-- | Creates and returns a renderer that renders a given FontString.
colorFontRenderer :: Window -> GeomRenderSource -> BezRenderSource -> Dpi
                  -> FontString -> (V2 Float -> V4 Float) -> IO Renderer
colorFontRenderer window grs brs dpi fstr clrf = do
    let (bs,ts) = fontGeom dpi fstr
        vs = concatMap (\(Triangle a b c) -> [a,b,c]) ts
        cs = map clrf vs
    clrr <- colorRenderer window grs GL_TRIANGLES vs cs

    let bcs = map ((\(Bezier _ a b c) -> Triangle a b c) . fmap clrf) bs
    bezr <- colorBezRenderer window brs bs bcs

    return $ stencilXOR $ clrr <> bezr

-- | Creates and returns a renderer that renders the given colored
-- geometry.
colorRenderer :: Window -> GeomRenderSource -> GLuint -> [V2 Float]
              -> [V4 Float] -> IO Renderer
colorRenderer window grs mode vs gs = do
    let (GRS src) = grs
        srcs = [src]

    withVAO $ \vao -> withBuffers 2 $ \[pbuf,cbuf] -> do
        let ps = map realToFrac $ concatMap F.toList vs :: [GLfloat]
            cs = map realToFrac $ concatMap F.toList $ take (length vs) gs :: [GLfloat]

        glDisableVertexAttribArray uvLoc
        glEnableVertexAttribArray colorLoc

        bufferAttrib positionLoc 2 pbuf ps
        bufferAttrib colorLoc 4 cbuf cs
        glBindVertexArray 0

        let num = fromIntegral $ length vs
            renderFunction t = do
                withUniform "hasUV" srcs $ \p huv -> do
                    glUseProgram p
                    glUniform1i huv 0
                withUniform "projection" srcs $ \p pju -> do
                    setOrthoWindowProjection window p pju
                withUniform "modelview" srcs $ \p mvu -> do
                    setModelview p mvu t
                drawBuffer (rsProgram src) vao mode num
            cleanupFunction = do
                withArray [pbuf, cbuf] $ glDeleteBuffers 2
                withArray [vao] $ glDeleteVertexArrays 1
        return $ Renderer renderFunction srcs cleanupFunction

-- | Creates and returns a renderer that renders the given textured
-- geometry.
textureRenderer :: Window -> GeomRenderSource -> GLuint -> GLuint -> [V2 Float]
                -> [V2 Float] -> IO Renderer
textureRenderer window grs t mode vs gs = do
    let (GRS src) = grs
        texr = Renderer (const $ glBindTexture GL_TEXTURE_2D t)
                        []
                        (withArray [t] $ glDeleteTextures 1)
        srcs = [src]

    withVAO $ \vao -> withBuffers 2 $ \[pbuf,cbuf] -> do
        let ps = map realToFrac $ concatMap F.toList vs :: [GLfloat]
            cs = map realToFrac $ concatMap F.toList $ take (length vs) gs :: [GLfloat]

        glDisableVertexAttribArray colorLoc
        glEnableVertexAttribArray uvLoc

        bufferAttrib positionLoc 2 pbuf ps
        bufferAttrib uvLoc 2 cbuf cs
        glBindVertexArray 0

        let num = fromIntegral $ length vs
            renderFunction tfrm = do
                withUniform "hasUV" srcs $ \p huv -> do
                    glUseProgram p
                    glUniform1i huv 1
                withUniform "sampler" srcs $ \p smp -> do
                    glUseProgram p
                    glUniform1i smp 0
                withUniform "projection" srcs $ \p pju -> do
                    setOrthoWindowProjection window p pju
                withUniform "modelview" srcs $ \p mvu -> do
                    setModelview p mvu tfrm
                drawBuffer (rsProgram src) vao mode num
            cleanupFunction = do
                withArray [pbuf, cbuf] $ glDeleteBuffers 2
                withArray [vao] $ glDeleteVertexArrays 1
            geomr = Renderer renderFunction srcs cleanupFunction
        return $ texr <> geomr

-- | Creates and returns a renderer that renders the given colored beziers.
colorBezRenderer :: Window -> BezRenderSource -> [Bezier (V2 Float)]
                 -> [Triangle (V4 Float)] -> IO Renderer
colorBezRenderer window (BRS src) bs ts =
    withVAO $ \vao -> withBuffers 3 $ \[pbuf, tbuf, cbuf] -> do
        let vs = concatMap (\(Bezier _ a b c) -> [a,b,c]) bs
            cvs = concatMap (\(Triangle a b c) -> [a,b,c]) $ take (length bs) ts
            ps = map realToFrac $ concatMap F.toList vs :: [GLfloat]
            cs = map realToFrac $ concatMap F.toList cvs :: [GLfloat]
            ws = concatMap (\(Bezier w _ _ _) -> let w' = fromBool $ w == LT
                                                 in [ 0, 0, w'
                                                    , 0.5, 0, w'
                                                    , 1, 1, w'
                                                    ])
                           bs :: [GLfloat]

        glDisableVertexAttribArray uvLoc
        glEnableVertexAttribArray colorLoc

        bufferAttrib positionLoc 2 pbuf ps
        bufferAttrib bezLoc 3 tbuf ws
        bufferAttrib colorLoc 4 cbuf cs
        glBindVertexArray 0

        let cleanupFunction = do
                withArray [pbuf, tbuf, cbuf] $ glDeleteBuffers 3
                withArray [vao] $ glDeleteVertexArrays 1
            num = fromIntegral $ length vs
            srcs = [src]
            renderFunction t = do
                withUniform "hasUV" srcs $ \p huv -> do
                    glUseProgram p
                    glUniform1i huv 0
                withUniform "projection" srcs $ \p pju -> do
                    setOrthoWindowProjection window p pju
                withUniform "modelview" srcs $ \p mvu -> do
                    setModelview p mvu t
                drawBuffer (rsProgram src) vao GL_TRIANGLES num
        return $ Renderer renderFunction srcs cleanupFunction

-- | Creates a renderer that masks all pixels that are drawn to an odd
-- number of times by the given renderer.
stencilXOR :: Renderer -> Renderer
stencilXOR (Renderer r s c) = Renderer r' s c
    where r' t = do glClear GL_DEPTH_BUFFER_BIT
                    glEnable GL_STENCIL_TEST
                    glColorMask GL_FALSE GL_FALSE GL_FALSE GL_FALSE
                    glDepthMask GL_FALSE
                    glStencilMask 0xFF
                    glClear GL_STENCIL_BUFFER_BIT
                    glStencilFunc GL_NEVER 0 1
                    glStencilOp GL_INVERT GL_INVERT GL_INVERT
                    r t

                    glColorMask GL_TRUE GL_TRUE GL_TRUE GL_TRUE
                    glDepthMask GL_TRUE
                    glStencilFunc GL_EQUAL 1 1
                    glStencilOp GL_ZERO GL_ZERO GL_ZERO
                    r t
                    glDisable GL_STENCIL_TEST

--------------------------------------------------------------------------------
-- Updating uniforms
--------------------------------------------------------------------------------
withUniform :: String -> [RenderSource] -> (GLuint -> GLint -> IO ()) -> IO ()
withUniform name srcs f = mapM_ update srcs
    where update (RenderSource p ls) = case lookup name ls of
                                           Nothing -> return ()
                                           Just u  -> do f p u

setOrthoWindowProjection :: Window -> GLuint -> GLint -> IO ()
setOrthoWindowProjection window program pju = do
    pj <- orthoWindowProjection window
    glUseProgram program
    with pj $ glUniformMatrix4fv pju 1 GL_TRUE . castPtr

setModelview :: GLuint -> GLint -> Transform -> IO ()
setModelview program uniform (Transform (V2 x y) (V2 w h) r) = do
    let mv = mat4Translate txy !*! rot !*! mat4Scale sxy :: M44 GLfloat
        sxy = V3 w h 1
        txy = V3 x y 0
        rxy = V3 0 0 1
        rot = if r /= 0 then mat4Rotate r rxy else eye4
    glUseProgram program
    with mv $ glUniformMatrix4fv uniform 1 GL_TRUE . castPtr

orthoWindowProjection :: Window -> IO (M44 GLfloat)
orthoWindowProjection window = do
    (ww, wh) <- getWindowSize window
    let (hw,hh) = (fromIntegral ww, fromIntegral wh)
    return $ ortho 0 hw hh 0 0 1
--------------------------------------------------------------------------------
-- Loading resources and things
--------------------------------------------------------------------------------

-- | Loads a new shader program and attributes for rendering geometry.
loadGeomRenderSource :: IO GeomRenderSource
loadGeomRenderSource = do
    let def = RenderDefBS [(vertSourceGeom, GL_VERTEX_SHADER)
                          ,(fragSourceGeom, GL_FRAGMENT_SHADER)]
                          ["projection", "modelview", "sampler", "hasUV"]
    GRS <$> loadRenderSource def

-- | Loads a new shader progarm and attributes for rendering beziers.
loadBezRenderSource :: IO BezRenderSource
loadBezRenderSource = do
    let def = RenderDefBS [(vertSourceBezier, GL_VERTEX_SHADER)
                          ,(fragSourceBezier, GL_FRAGMENT_SHADER)
                          ]
                          ["projection", "modelview", "sampler", "hasUV"]
    BRS <$> loadRenderSource def

loadRenderSource :: RenderDef -> IO RenderSource
loadRenderSource (RenderDefBS ss uniforms) = do
    shaders <- mapM (uncurry compileShader) ss
    program <- compileProgram shaders
    glUseProgram program
    locs <- forM uniforms $ \attr -> do
        loc <- withCString attr $ glGetUniformLocation program
        return $ if loc == (-1)
                 then Nothing
                 else Just (attr, loc)
    return $ RenderSource program $ catMaybes locs
loadRenderSource (RenderDefFP fps uniforms) = do
    cwd <- getCurrentDirectory
    srcs <- forM fps $ \(fp, shaderType) -> do
        src <- B.readFile $ cwd ++ "/" ++ fp
        return (src, shaderType)
    loadRenderSource $ RenderDefBS srcs uniforms

loadTexture :: DynamicImage -> IO GLuint
loadTexture img = do
    putStrLn "Loading texture"
    [t] <- allocaArray 1 $ \ptr -> do
        glGenTextures 1 ptr
        peekArray 1 ptr
    glBindTexture GL_TEXTURE_2D t
    loadJuicy img
    glGenerateMipmap GL_TEXTURE_2D  -- Generate mipmaps now!!!
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S GL_REPEAT
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T GL_REPEAT
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_LINEAR
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_LINEAR_MIPMAP_LINEAR
    -- glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_NEAREST
    -- glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_NEAREST
    -- glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S GL_REPEAT
    -- glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T GL_REPEAT
    -- glBindTexture GL_TEXTURE_2D 0
    return t

loadJuicy :: DynamicImage -> IO ()
loadJuicy (ImageY8 (Image w h d)) = bufferImageData w h d GL_RED GL_UNSIGNED_BYTE
loadJuicy (ImageY16 (Image w h d)) = bufferImageData w h d GL_RED GL_UNSIGNED_SHORT
loadJuicy (ImageYF (Image w h d)) = bufferImageData w h d GL_RED GL_FLOAT
loadJuicy (ImageYA8 i) = loadJuicy $ ImageRGB8 $ promoteImage i
loadJuicy (ImageYA16 i) = loadJuicy $ ImageRGBA16 $ promoteImage i
loadJuicy (ImageRGB8 (Image w h d)) = bufferImageData w h d GL_RGB GL_UNSIGNED_BYTE
loadJuicy (ImageRGB16 (Image w h d)) = bufferImageData w h d GL_RGB GL_UNSIGNED_SHORT
loadJuicy (ImageRGBF (Image w h d)) = bufferImageData w h d GL_RGB GL_FLOAT
loadJuicy (ImageRGBA8 (Image w h d)) = bufferImageData w h d GL_RGBA GL_UNSIGNED_BYTE
loadJuicy (ImageRGBA16 (Image w h d)) = bufferImageData w h d GL_RGBA GL_UNSIGNED_SHORT
loadJuicy (ImageYCbCr8 i) = loadJuicy $ ImageRGB8 $ convertImage i
loadJuicy (ImageCMYK8 i) = loadJuicy $ ImageRGB8 $ convertImage i
loadJuicy (ImageCMYK16 i) = loadJuicy $ ImageRGB16 $ convertImage i


toTexture :: (Int, Int) -> IO () -> IO GLuint
toTexture (w, h) r = do
    [fb] <- allocaArray 1 $ \ptr -> do
        glGenFramebuffers 1 ptr
        peekArray 1 ptr
    glBindFramebuffer GL_FRAMEBUFFER fb

    [t] <- allocaArray 1 $ \ptr -> do
        glGenTextures 1 ptr
        peekArray 1 ptr
    glBindTexture GL_TEXTURE_2D t
    let [w',h'] = map fromIntegral [w,h]
    glTexImage2D GL_TEXTURE_2D
                 0
                 GL_RGBA
                 w'
                 h'
                 0
                 GL_RGBA
                 GL_UNSIGNED_BYTE
                 nullPtr
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_NEAREST
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_NEAREST

{-
    [d] <- allocaArray 1 $ \ptr -> do
        glGenRenderbuffers 1 ptr
        peekArray 1 ptr
    glBindRenderbuffer GL_RENDERBUFFER d
    glRenderbufferStorage GL_RENDERBUFFER GL_DEPTH_COMPONENT w' h'
    glFramebufferRenderbuffer GL_FRAMEBUFFER GL_DEPTH_ATTACHMENT GL_RENDERBUFFER d
-}

    glFramebufferTexture GL_FRAMEBUFFER GL_COLOR_ATTACHMENT0 t 0
    withArray [GL_COLOR_ATTACHMENT0] $ glDrawBuffers 1

    status <- glCheckFramebufferStatus GL_FRAMEBUFFER
    if status /= GL_FRAMEBUFFER_COMPLETE
    then putStrLn "incomplete framebuffer!"
    else do glClearColor 0 0 0 0
            glClear GL_COLOR_BUFFER_BIT
            glViewport 0 0 w' h'
            r
            glBindFramebuffer GL_FRAMEBUFFER 0
            with fb $ glDeleteFramebuffers 1
    return t

calculateDpi :: IO Dpi
calculateDpi = do
    mMonitor <- getPrimaryMonitor

    -- Calculate the dpi of the primary monitor.
    case mMonitor of
        -- I've choosen 128 as the default DPI because of my macbook 15"
        Nothing -> return 128
        Just m  -> do (w, h) <- getMonitorPhysicalSize m
                      mvmode <- getVideoMode m
                      case mvmode of
                          Nothing -> return 128
                          Just (VideoMode vw vh _ _ _ _) -> do
                              let mm2 = fromIntegral $ w*h :: Double
                                  px  = sqrt $ (fromIntegral vw :: Double)*(fromIntegral vh)
                                  inches = sqrt $ mm2 / (25.4 * 25.4)
                              let dpi = floor $ px / inches
                              putStrLn $ "Dpi: " ++ show dpi
                              return dpi

compileFontCache :: IO (Async FontCache)
compileFontCache = async $ do
    putStrLn "Loading font cache."
    a <- buildCache
    putStrLn "Font cache loaded."
    return a


--resources :: Window -> IO Resources
--resources window = do
--    -- Calculate the dpi of the primary monitor.
--    dpi <- calculateDpi
--    a <- compileFontCache
--    t <- getCurrentTime
--    return $ Resources { rsrcFonts = a
--                       , rsrcRenderers = IM.empty
--                       , rsrcSources = M.empty
--                       , rsrcWindow = window
--                       , rsrcDpi = dpi
--                       , rsrcUTC = t
--                       }

--------------------------------------------------------------------------------
-- Buffering, Vertex Array Objects, Uniforms, etc.
--------------------------------------------------------------------------------
bufferImageData :: forall a a1 a2. (Storable a2, Integral a1, Integral a) => a -> a1 -> Vector a2 -> GLenum -> GLenum -> IO ()
bufferImageData w h dat imgfmt pxfmt = unsafeWith dat $ \ptr -> do
    --glTexStorage2D GL_TEXTURE_2D 1 GL_RGBA8 (fromIntegral w) (fromIntegral h)
    --glTexSubImage2D GL_TEXTURE_2D 0 0 0 (fromIntegral w) (fromIntegral h) GL_RGBA GL_UNSIGNED_BYTE (castPtr ptr)
    glTexImage2D
        GL_TEXTURE_2D
        0
        GL_RGBA
        (fromIntegral w)
        (fromIntegral h)
        0
        imgfmt
        pxfmt
        (castPtr ptr)
    err <- glGetError
    when (err /= 0) $ putStrLn $ "glTexImage2D Error: " ++ show err

withVAO :: (GLuint -> IO b) -> IO b
withVAO f = do
    [vao] <- allocaArray 1 $ \ptr -> do
        glGenVertexArrays 1 ptr
        peekArray 1 ptr
    glBindVertexArray vao
    r <- f vao
    glBindVertexArray vao
    return r

withBuffers :: Int -> ([GLuint] -> IO b) -> IO b
withBuffers n f = do
    bufs <- allocaArray n $ \ptr -> do
        glGenBuffers (fromIntegral n) ptr
        peekArray (fromIntegral n) ptr
    f bufs

bufferAttrib :: Storable a => GLuint -> GLint -> GLuint -> [a] -> IO ()
bufferAttrib loc n buf as = do
    let asize = length as * glFloatSize
    glBindBuffer GL_ARRAY_BUFFER buf
    withArray as $ \ptr ->
        glBufferData GL_ARRAY_BUFFER (fromIntegral asize) (castPtr ptr) GL_STATIC_DRAW
    glEnableVertexAttribArray loc
    glVertexAttribPointer loc n GL_FLOAT GL_FALSE 0 nullPtr

drawBuffer :: GLuint
           -> GLuint
           -> GLenum
           -> GLsizei
           -> IO ()
drawBuffer program vao mode num = do
    glUseProgram program
    --case (,) <$> uuProjection <*> uuModelview of
    --    Nothing -> return ()
    --    Just (pju,mvu) -> do setOrthoWindowProjection window program pju
    --                         setModelview program mvu tfrm
    --let (spu,spub) = uuSampler
    --    (hvu,hvub) = uuHasUV
    --glUniform1i spu spub
    --glUniform1i hvu hvub
    glBindVertexArray vao
    err <- glGetError
    when (err /= 0) $ putStrLn $ "glBindVertex Error: " ++ show err
    glDrawArrays mode 0 num
    err' <- glGetError
    when (err /= 0) $ putStrLn $ "glDrawArrays Error: " ++ show err'


glFloatSize :: Int
glFloatSize = sizeOf (undefined :: GLfloat)

--enableBlending :: SetMember Lift (Lift IO) r => IO ()
--enableBlending = lift $ do
--    glEnable GL_BLEND
--    glBlendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA

--drawClear :: (Member (State Resources) r,
--              SetMember Lift (Lift IO) r) => IO ()
--drawClear = do
--    (fbw, fbh) <- framebufferSize
--    lift $ do
--        pollEvents
--        glViewport 0 0 (fromIntegral fbw) (fromIntegral fbh)
--        glClear $ GL_COLOR_BUFFER_BIT .|. GL_DEPTH_BUFFER_BIT

--framebufferSize :: (Member (State Resources) r,
--                    SetMember Lift (Lift IO) r) => IO (Int, Int)
--framebufferSize = gets rsrcWindow >>= lift . getFramebufferSize

--withNewFrame :: (Member (State Resources) r,
--                 SetMember Lift (Lift IO) r)
--             => IO () -> IO ()
--withNewFrame f = do
--    t <- lift $ do pollEvents
--                   getCurrentTime
--    modify $ \rsrcs -> rsrcs{rsrcUTC = t}
--    f
--    window <- gets rsrcWindow
--    lift $ do
--        swapBuffers window
--        shouldClose <- windowShouldClose window
--        if shouldClose
--        then exitSuccess
--        else threadDelay 100

