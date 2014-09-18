module Gelatin.Compiling where

import Gelatin.Rendering
import Gelatin.ShaderCommands
import Gelatin.TextureCommands
import Graphics.VinylGL
import Graphics.GLUtil hiding (Elem, setUniform)
import Graphics.Rendering.OpenGL hiding (Color, position, color, VertexComponent)
import qualified Graphics.Rendering.OpenGL as GL
import Control.Monad
import Control.Monad.Free
import Control.Monad.Free.Church
import Data.Vinyl
import Data.Monoid
import Data.Either
import Foreign
import Linear (V4(..))

data RenderingDefaults = RenderingDefaults { rdefDepthFunc     :: Maybe ComparisonFunction
                                           , rdefShaderProgram :: Maybe ShaderProgram
                                           , rdefClearColor    :: Color4 GLfloat
                                           }

--------------------------------------------------------------------------------
-- Compiling/Running
--------------------------------------------------------------------------------
compileDrawElementsCommand :: Free DrawElements () -> IO CompiledRendering
compileDrawElementsCommand (Pure ()) = return mempty
compileDrawElementsCommand (Free (DrawElements n mode next)) =
    fmap (prefixRender $ GL.drawElements mode n UnsignedInt nullPtr) $
        compileDrawElementsCommand next

compileShaderCommand :: ShaderProgram -> Free ShaderOp () -> IO CompiledRendering
compileShaderCommand _ (Pure ()) = return mempty
compileShaderCommand s (Free (SetUniform u m next)) =
    fmap (prefixRender $ setUniforms s (u =: m)) $ compileShaderCommand s next
compileShaderCommand s (Free (WithVertices vs cmd next)) = do
    sub <- compileShaderCommand s $ fromF cmd
    nxt <- compileShaderCommand s next
    vbo <- bufferVertices vs
    let io = do bindVertices vbo
                enableVertices' s vbo
                render sub
        cu = do cleanup sub
                deleteVertices vbo
    return $ nxt `mappend` Compiled io cu
compileShaderCommand s (Free (WithIndices ns cmd next)) = do
    sub <- compileDrawElementsCommand $ fromF cmd
    nxt <- compileShaderCommand s next
    ebo <- bufferIndices ns
    let io = do bindBuffer ElementArrayBuffer $= Just ebo
                render sub
        cu = do cleanup sub
                bindBuffer ElementArrayBuffer $= Nothing
    return $ nxt `mappend` Compiled io cu
compileShaderCommand s (Free (DrawArrays mode i next)) =
    fmap (prefixRender $ GL.drawArrays mode 0 i) $ compileShaderCommand s next

compileTextureCommand :: ParameterizedTextureTarget t
                      => t -> Free TextureOp () -> IO CompiledRendering
compileTextureCommand _ (Pure ()) = return mempty
compileTextureCommand t (Free (SetFilter mn mg n)) =
    fmap (prefixRender $ textureFilter t $= (mn, mg)) $
        compileTextureCommand t n
compileTextureCommand t (Free (SetWrapMode c rp clamp n)) =
    fmap (prefixRender $ textureWrapMode t c $= (rp, clamp)) $
        compileTextureCommand t n

compileRenderCommand :: Free Render () -> IO CompiledRendering
compileRenderCommand (Pure ()) = return mempty
compileRenderCommand (Free (UsingDepthFunc func r next)) = do
    sub <- compileRenderCommand $ fromF r
    nxt <- compileRenderCommand next
    let io = do depthFunc $= Just func
                render sub
        cu = do cleanup sub
                depthFunc $= Nothing
    return $ nxt `mappend` Compiled io cu
compileRenderCommand (Free (UsingShader s sc next)) = do
    sub <- compileShaderCommand s $ fromF sc
    nxt <- compileRenderCommand next
    let io = do currentProgram $= (Just $ program s)
                render sub
        cu = do cleanup sub
                currentProgram $= Nothing
    return $ nxt `mappend` Compiled io cu
compileRenderCommand (Free (ClearDepth next)) = do
    fmap (prefixRender $ clear [DepthBuffer]) $ compileRenderCommand next
compileRenderCommand (Free (ClearColorWith c next)) = do
    fmap (prefixRender $ clearColor $= (toColor4 c) >> clear [ColorBuffer]) $
        compileRenderCommand next
compileRenderCommand (Free (UsingTextures t ts cmd r n)) = do
    ts' <- putStrLn "Loading textures..." >> loadTextures t (fromF cmd) ts
    sub <- compileRenderCommand $ fromF r
    nxt <- compileRenderCommand n
    let io = withTextures t ts' $ render sub
        cu = do cleanup sub
    return $ nxt `mappend` Compiled io cu


loadTextures :: ( BindableTextureTarget t
                , ParameterizedTextureTarget t
                )
             => t -> TextureCommand () -> [TextureSrc] -> IO [TextureObject]
loadTextures t cmd srcs = do
    texparams <- compileTextureCommand t $ fromF cmd
    texture t $= Enabled
    fmap rights $ forM srcs $ loadAndInitTex texparams

loadAndInitTex :: CompiledRendering -> TextureSrc -> IO (Either String TextureObject)
loadAndInitTex r src = do
    eT <- loadTextureSrc src
    case eT of
        Right t  -> render r >> return (Right t)
        Left err -> putStrLn err >> return (Left err)

toColor4 :: Real a => V4 a -> Color4 GLfloat
toColor4 v = Color4 r g b a
    where (V4 r g b a) = fmap realToFrac v

compileRendering :: Rendering () -> IO CompiledRendering
compileRendering = compileRenderCommand . fromF