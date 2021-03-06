{-# LANGUAGE TemplateHaskell, TypeFamilies, TypeSynonymInstances, EmptyDataDecls #-}
module Main where

import Control.Applicative(Applicative((<*>),pure), (<$>), (*>))
import Control.Monad.Consumer(next)
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Time (UTCTime, getCurrentTime)
import Generics.Regular
import Web.Routes.Wai
import Network.Wai 
import Network.Wai.Enumerator
import Network.Wai.Handler.SimpleServer (run)
import Text.Html ((!), (<<), (+++), Html, anchor, body, href, toHtml, renderHtml, header, thetitle)
import Web.Routes
import Web.Routes.TH
import Web.Routes.Regular
import Web.Routes.Wai
import Test.QuickCheck (Arbitrary(..), oneof, quickCheck)
import System.FilePath((</>))

-- NOTE: in these examples the homepage is:
-- http://localhost:3000/MyHome

-- The URL / route types

data BlogURL
  = BlogHome
  | BlogPost String
    deriving (Eq, Ord, Read, Show)
             
data SiteURL
  = MyHome
  | MyBlog BlogURL
    deriving (Eq, Ord, Read, Show)
             
-- wrapper function for generating HTML pages
             
page :: Html -> Html             
page contents = 
  header (thetitle  (toHtml "title")) +++ body contents
             
-- the BlogURL route handler Application
--
-- In this version, the function for converting the URL type to its
-- String representation is passed in as the argument mkAbs.
myBlog :: UTCTime -> (BlogURL -> String) -> BlogURL -> Application
myBlog now mkAbs BlogHome _request =
  return $ Response Status200 h $ Right c
    where
      h = [(ContentType, S.pack "text/html")]
      c = fromLBS $ L.pack $ renderHtml $ page (anchor ! [ href (mkAbs $ BlogPost "hello-world")] << (toHtml "hello-world"))
myBlog now mkAbs (BlogPost title) _request =
     return $ Response Status200 h $ Right c
      where
        h = [(ContentType, S.pack "text/plain")]
        c = fromLBS $ L.pack $ unlines
                [ mkAbs BlogHome
                , title
                , show now
                ]

-- the SiteURL route handler Application
-- In this version, the function for converting the URL type to its
-- String representation is passed in as the argument mkAbs.
mySite :: UTCTime -> (SiteURL -> String) -> SiteURL -> Application
mySite _now mkAbs MyHome _request = 
  return $ Response Status200 h $ Right c
      where
        h = [(ContentType, S.pack "text/html")]
        c = fromLBS $ L.pack $ renderHtml $ page (anchor ! [ href (mkAbs $ MyBlog $ BlogPost "hello-world")] << (toHtml "hello-world"))
mySite now mkAbs (MyBlog blogURL) request =
        myBlog now (mkAbs . MyBlog) blogURL request

-- example using of using just handleWai_
main1 :: IO ()
main1 =
  do now <- getCurrentTime
     let fromAbs str =
           case decodePathInfo str of
             [p] -> case reads p of
               [(n,[])] -> Right n
               _ -> Left ("Failed to parse as url: " ++ str) 
             _ -> Left ("Failed to parse as url: " ++ str)
         mkAbs s     = '/' : encodePathInfo [show s]
     run 3000 $ handleWai_ mkAbs fromAbs "http://localhost:3000" (mySite now) 
     
-- we can neatly wrap up the handler with it's mkAbs / fromAbs functions like this:     
     
mySiteSpec :: UTCTime -> Site SiteURL Application
mySiteSpec now =     
 setDefault MyHome $
  Site { handleSite          = mySite now
       , formatPathSegments  = \url -> [show url]
       , parsePathSegments   = \segs ->
         case segs of
             [p] -> case reads p of
               [(n,[])] -> Right n
               _ -> Left ("Failed to parse as url: " ++ show segs) 
             _ -> Left ("Failed to parse as url: " ++ show segs)
       }

-- and call it like this:

mainSite :: IO ()
mainSite =
  do now <- getCurrentTime
     let siteSpec = mySiteSpec now
     run 3000 $ waiSite siteSpec "http://localhost:3000/"
     
-- We can also use PathInfo to record the way to convert a url to path
-- segments and back. 
     
-- Here we use TH to derive PathInfo instances     

$(derivePathInfo ''BlogURL)

-- instead of using template haskell to generate to PathInfo
-- instances, we could use the RouteT.Regular
-- alas we can only have on PathInfo instance at a time for UserRoute     


$(deriveAll ''SiteURL "PFSiteURL")
type instance PF SiteURL = PFSiteURL

instance PathInfo SiteURL where
  toPathSegments   = gtoPathSegments . from   
  fromPathSegments = fmap to gfromPathSegments

-- $(derivePathInfo ''SiteURL)

-- and we can use them easily like this:
mainPathInfo :: IO ()
mainPathInfo =
  do now <- getCurrentTime
     run 3000 $ handleWai "http://localhost:3000" (mySite now)
     
-- we can test the the functions in PathInfo are inverses using pathInfoInverse_prop
     
instance Arbitrary BlogURL where
  arbitrary = oneof [ pure BlogHome
                    , BlogPost <$> arbitrary
                    ]
     
instance Arbitrary SiteURL where              
  arbitrary = oneof [ pure MyHome
                    , MyBlog <$> arbitrary
                    ]
     
mainProp :: IO ()     
mainProp = quickCheck (pathInfoInverse_prop :: (SiteURL -> Bool))

-- Instead of passing the mkAbs function around manually, we can use
-- the RouteT monad transformer

-- the BlogURL route handler Application
--
-- In this version, the function for converting the URL type to its
-- String representation is passed in as the argument mkAbs.
myBlogM :: UTCTime -> BlogURL -> (Request -> RouteT BlogURL IO Response)
myBlogM now BlogHome _request =
  do postURL <- showURL $ BlogPost "hello-world"
     return $ Response Status200 h $ Right (c postURL)
    where
      h = [(ContentType, S.pack "text/html")]
      c postURL = fromLBS $ L.pack $ renderHtml $ page (anchor ! [ href postURL] << (toHtml "hello-world"))

myBlogM now (BlogPost title) _request =
  do postURL <- showURL $ BlogPost "hello-world"
     return $ Response Status200 h $ Right (c postURL)
      where
        h = [(ContentType, S.pack "text/plain")]
        c postURL 
          = fromLBS $ L.pack $ unlines
            [ postURL
            , title
            , show now
            ]

-- the SiteURL route handler Application
-- In this version, the function for converting the URL type to its
-- String representation is passed in as the argument mkAbs.
mySiteM :: UTCTime -> SiteURL -> (Request -> RouteT SiteURL IO Response)
mySiteM _now MyHome _request = 
  do postURL <- showURL (MyBlog $ BlogPost "hello-world")
     return $ Response Status200 h $ Right (c postURL)
      where
        h = [(ContentType, S.pack "text/html")]
        c postURL = fromLBS $ L.pack $ renderHtml $ page (anchor ! [ href postURL] << (toHtml "hello-world"))
mySiteM now (MyBlog blogURL) request =
        nestURL MyBlog $ myBlogM now blogURL request

mainRouteT :: IO ()
mainRouteT =
  do now <- getCurrentTime
     run 3000 $ handleWaiRouteT "http://localhost:3000" (mySiteM now)

{-
-- tests for parcec based PathInfo
      
test :: IO ()
test = 
  let segments = ["foo", "hi", "there", "world"] in
  case parse testp (show segments) segments of
    (Left e) -> putStrLn $ showParseError e
    (Right r) -> print r
  
testp :: URLParser (Char, String, String)
testp =  
  do segment "foo"
     st <- p2u (char 'h' >> char 'o')
     sg <- anySegment
     sg' <- anySegment
     return (st,sg, sg')
-}