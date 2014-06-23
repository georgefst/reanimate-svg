{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Graphics.Svg.CssParser
    ( CssElement( .. )
    , complexNumber
    , declaration
    , unitNumber
    , ruleSet
    , styleString
    , num
    )
    where

import Control.Applicative( (<$>), (<$)
                          , (<*>), (<*), (*>)
                          , (<|>)
                          , many
                          , pure
                          )
import Data.Attoparsec.Text
    ( Parser
    , double
    , string
    , skipSpace
    , letter
    , char
    , digit
    {-, skip-}
    , sepBy1
    , (<?>)
    , skipMany
    {-, satisfy-}
    , notChar
    )
import qualified Data.Attoparsec.Text as AT

import Data.Attoparsec.Combinator
    ( option
    , sepBy
    {-, sepBy1-}
    , many1
    )

import Codec.Picture( PixelRGBA8( .. ) )
import Graphics.Svg.Types
import Data.Text( Text )
import Graphics.Svg.NamedColors( svgNamedColors )
import Graphics.Svg.ColorParser( colorParser )
import Graphics.Svg.CssTypes
import qualified Data.Text as T
import qualified Data.Map as M
{-import Graphics.Rasterific.Linear( V2( V2 ) )-}
{-import Graphics.Rasterific.Transformations-}

num :: Parser Float
num = realToFrac <$> (skipSpace *> plusMinus <* skipSpace)
  where doubleNumber = char '.' *> (scale <$> double)
                    <|> double

        scalingCoeff n = 10 ^ digitCount
          where digitCount :: Int
                digitCount = ceiling . logBase 10 $ abs n

        scale n = n / scalingCoeff n

        plusMinus = negate <$ string "-" <*> doubleNumber
                 <|> string "+" *> doubleNumber
                 <|> doubleNumber


ident :: Parser Text
ident =
  (\f c -> f . T.cons c . T.pack)
        <$> trailingSub
        <*> nmstart <*> nmchar
  where
    trailingSub = option id $ (T.cons '-') <$ char '-'
    underscore = char '_'
    nmstart = letter <|> underscore
    nmchar = many (letter <|> digit <|> underscore <|> char '-')

str :: Parser Text
str = char '"' *> AT.takeWhile (/= '"') <* char '"' <* skipSpace
   <?> "str"

between :: Char -> Char -> Parser a -> Parser a
between o e p =
  (skipSpace *>
      char o *> skipSpace *> p
           <* skipSpace <* char e <* skipSpace)
           <?> ("between " ++ [o, e])

bracket :: Parser a -> Parser a
bracket = between '[' ']'

{-
: 	:
; 	;
{ 	\{
} 	\}
( 	\(
) 	\)
[ 	\[
] 	\]
S 	[ \t\r\n\f]+
COMMENT 	\/\*[^*]*\*+([^/*][^*]*\*+)*\/
FUNCTION 	{ident}\(
INCLUDES 	~=
DASHMATCH 	|
-}

{-  
stylesheet
  : [ CHARSET_SYM STRING ';' ]?
    [S|CDO|CDC]* [ import [ CDO S* | CDC S* ]* ]*
    [ [ ruleset | media | page ] [ CDO S* | CDC S* ]* ]*
  ;
-- -}

comment :: Parser ()
comment = string "/*" *> toStar *> skipSpace
  where
    toStar = skipMany (notChar '*') *> char '*' *> testEnd
    testEnd = (() <$ char '/') <|> toStar

cleanSpace :: Parser ()
cleanSpace = skipSpace <* many comment

-- | combinator: '+' S* | '>' S*
combinator :: Parser CssSelector
combinator = parse <* cleanSpace where
  parse = Nearby <$ char '+'
       <|> DirectChildren <$ char '>'
       <?> "combinator"

-- unary_operator : '-' | '+' ;

ruleSet :: Parser CssRule
ruleSet = cleanSpace *> rule where
  commaWsp = skipSpace *> char ',' <* skipSpace
  rule = CssRule
      <$> selector `sepBy1` commaWsp
      <*> between '{' '}' styleString
      <?> "cssrule"

styleString :: Parser [CssDeclaration]
styleString = declaration `sepBy` semiWsp 
  where semiWsp = skipSpace *> char ';' <* skipSpace

selector :: Parser [CssSelector]
selector = (:)
        <$> (AllOf <$> simpleSelector <* skipSpace <?> "firstpart:(")
        <*> ((next <|> return []) <?> "secondpart")
        <?> "selector"
  where
    combOpt :: Parser ([CssSelector] -> [CssSelector])

    combOpt = cleanSpace *> (option id $ (:) <$> combinator)
    next :: Parser [CssSelector]
    next = id <$> combOpt <*> selector

simpleSelector :: Parser [CssDescriptor]
simpleSelector = (:) <$> elementName <*> many whole
              <|> (many1 whole <?> "inmany")
              <?> "simple selector"
 where
  whole = pseudo <|> hash <|> classParser <|> attrib
       <?> "whole"
  pseudo = char ':' *> (OfPseudoClass <$> ident)
        <?> "pseudo"
  hash = char '#' *> (OfId <$> ident)
      <?> "hash"
  classParser = char '.' *> (OfClass <$> ident)
              <?> "classParser"

  elementName = el <* skipSpace <?> "elementName"
    where el = (OfName <$> ident)
            <|> AnyElem <$ char '*'

  attrib = (bracket $
    WithAttrib <$> ident <*> (char '=' *> skipSpace *> (ident <|> str)))
           <?> "attrib"

declaration :: Parser CssDeclaration
declaration =
  CssDeclaration <$> property
                 <*> (char ':' 
                      *> cleanSpace
                      *> many1 expr
                      <* prio
                      )
                 <?> "declaration"
  where
    property = ident <* cleanSpace
    prio = option "" $ string "!important"

operator :: Parser CssElement
operator = op <* skipSpace
  where
    op = CssOpSlash <$ char '/'
      <|> CssOpComa <$ char ',' 
      <?> "operator"

expr :: Parser [CssElement]
expr = ((:) <$> term <*> (concat <$> many termOp))
    <?> "expr"
  where
    op = option (:[]) $ (\a b -> [a, b]) <$> operator
    termOp = ($) <$> op <*> term

unitParser :: Parser (Float -> Float)
unitParser =
      (* 1.25) <$ "pt"
  <|> (* 15) <$ "pc"
  <|> (* 3.543307) <$ "mm"
  <|> (* 35.43307) <$ "cm"
  <|> (* 90) <$ "in"
  <|> id <$ "px"
  <|> pure id

unitNumber :: Parser Float
unitNumber = do
  n <- num
  f <- unitParser
  return $ f n

complexNumber :: Parser SvgNumber
complexNumber = do
    n <- num
    let apply f = SvgNum $ f n
    (SvgPercent (n / 100) <$ char '%')
        <|> (SvgEm n <$ string "em")
        <|> (apply <$> unitParser)
        <|> pure (SvgNum n)

term :: Parser CssElement
term = checkRgb <$> function
    <|> (CssNumber <$> complexNumber)
    <|> (CssString <$> str)
    <|> (checkNamedColor <$> ident)
    <|> (CssColor <$> colorParser)
  where
    comma = char ',' <* skipSpace
    checkNamedColor n 
        | Just c <- M.lookup n svgNamedColors = CssColor c
        | otherwise = CssIdent n

    checkRgb (CssFunction "rgb"
                [CssNumber r, CssNumber g, CssNumber b]) =
        CssColor $ PixelRGBA8 (to r) (to g) (to b) 255
       where clamp = max 0 . min 255
             to (SvgNum n) = floor $ clamp n 
             to (SvgPercent p) = floor . clamp $ p * 255
             to (SvgEm c) = floor $ clamp c

    checkRgb a = a

    function = CssFunction
       <$> ident <* char '('
       <*> (term `sepBy` comma) <* char ')' <* skipSpace
