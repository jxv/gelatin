{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Gelatin.Core.Shader (
    -- * Attribute layout locations
    -- $layout
    positionLoc,
    colorLoc,
    uvLoc,
    bezLoc,
    normLoc,
    miterLoc,
    -- * Enabling and disabling attribs
    onlyEnableAttribs,
    -- * Shader source files
    vertSourcePoly,
    fragSourcePoly,
    vertSourceGeom,
    fragSourceGeom,
    vertSourceBezier,
    fragSourceBezier,
    vertSourceMask,
    fragSourceMask,
    -- * Shader compilation
    compileShader,
    compileProgram,
) where

import Prelude hiding (init)
import Prelude as P
import Graphics.GL.Core33
import Graphics.GL.Types
import Control.Monad
import System.Exit
import Foreign.Ptr
import Foreign.C.String
import Foreign.Marshal.Array
import Foreign.Marshal.Utils
import Foreign.Storable
import Data.ByteString.Char8 as B
import Data.FileEmbed
--------------------------------------------------------------------------------
-- $layout
-- Attributes layout locations are unique and global.
--------------------------------------------------------------------------------
positionLoc :: GLuint
positionLoc = 0

colorLoc :: GLuint
colorLoc = 1

uvLoc :: GLuint
uvLoc = 2

bezLoc :: GLuint
bezLoc = 3

normLoc :: GLuint
normLoc = 4

miterLoc :: GLuint
miterLoc = 5

allLocs :: [GLuint]
allLocs = [0..5]

-- | Enables the provided attributes and disables all others.
onlyEnableAttribs :: [GLuint] -> IO ()
onlyEnableAttribs atts = do
   mapM_ glDisableVertexAttribArray allLocs
   mapM_ glEnableVertexAttribArray atts
--------------------------------------------------------------------------------
-- Shader compilation
--------------------------------------------------------------------------------
compileShader :: ByteString -> GLuint -> IO GLuint
compileShader src sh = do
    shader <- glCreateShader sh
    when (shader == 0) $ do
        B.putStrLn "could not create shader"
        exitFailure

    withCString (B.unpack src) $ \ptr ->
       with ptr $ \ptrptr -> glShaderSource shader 1 ptrptr nullPtr

    glCompileShader shader
    success <- with (0 :: GLint) $ \ptr -> do
        glGetShaderiv shader GL_COMPILE_STATUS ptr
        peek ptr

    when (success == GL_FALSE) $ do
        B.putStrLn "could not compile shader:\n"
        B.putStrLn src
        infoLog <- with (0 :: GLint) $ \ptr -> do
            glGetShaderiv shader GL_INFO_LOG_LENGTH ptr
            logsize <- peek ptr
            allocaArray (fromIntegral logsize) $ \logptr -> do
                glGetShaderInfoLog shader logsize nullPtr logptr
                peekArray (fromIntegral logsize) logptr
        P.putStrLn $ P.map (toEnum . fromEnum) infoLog
        exitFailure

    return shader

compileProgram :: [GLuint] -> IO GLuint
compileProgram shaders = do
    program <- glCreateProgram

    forM_ shaders (glAttachShader program)
    glLinkProgram program

    success <- with (0 :: GLint) $ \ptr -> do
        glGetProgramiv program GL_LINK_STATUS ptr
        peek ptr

    when (success == GL_FALSE) $ do
        B.putStrLn "could not link program"
        infoLog <- with (0 :: GLint) $ \ptr -> do
            glGetProgramiv program GL_INFO_LOG_LENGTH ptr
            logsize <- peek ptr
            allocaArray (fromIntegral logsize) $ \logptr -> do
                glGetProgramInfoLog program logsize nullPtr logptr
                peekArray (fromIntegral logsize) logptr
        P.putStrLn $ P.map (toEnum . fromEnum) infoLog
        exitFailure

    forM_ shaders glDeleteShader
    return program
--------------------------------------------------------------------------------
-- Shader sources
--------------------------------------------------------------------------------
vertSourcePoly :: ByteString
vertSourcePoly = $(embedFile "shaders/line.vert")

fragSourcePoly :: ByteString
fragSourcePoly = $(embedFile "shaders/line.frag")

vertSourceGeom :: ByteString
vertSourceGeom = $(embedFile "shaders/2d.vert")

fragSourceGeom :: ByteString
fragSourceGeom = $(embedFile "shaders/2d.frag")

vertSourceBezier :: ByteString
vertSourceBezier = $(embedFile "shaders/bezier.vert")

fragSourceBezier :: ByteString
fragSourceBezier = $(embedFile "shaders/bezier.frag")

vertSourceMask :: ByteString
vertSourceMask = $(embedFile "shaders/mask.vert")

fragSourceMask :: ByteString
fragSourceMask = $(embedFile "shaders/mask.frag")