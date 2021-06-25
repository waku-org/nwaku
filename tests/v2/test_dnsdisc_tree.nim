{.used.}

import
  std/[sequtils, strutils],
  testutils/unittests,
  chronos,
  stew/[base64, results],
  ../../waku/v2/dnsdisc/tree

procSuite "Test DNS Discovery: Merkle Tree":

  asyncTest "Parse root entry":
    # Expected case
    let entryRes = parseRootEntry("enrtree-root:v1 e=JWXYDBPXYWG6FX3GMDIBFA6CJ4 l=C7HRFPF3BLGF3YR4DY5KX3SMBE seq=1 sig=o908WmNp7LibOfPsr4btQwatZJ5URBr2ZAuxvK4UWHlsB9sUOTJQaGAlLPVAhM__XJesCHxLISo94z5Z2a463gA")
    
    check:
      entryRes.isOk()
      entryRes[].eroot == "JWXYDBPXYWG6FX3GMDIBFA6CJ4"
      entryRes[].lroot == "C7HRFPF3BLGF3YR4DY5KX3SMBE"
      entryRes[].seqNo == 1
      entryRes[].signature == Base64Url.decode("o908WmNp7LibOfPsr4btQwatZJ5URBr2ZAuxvK4UWHlsB9sUOTJQaGAlLPVAhM__XJesCHxLISo94z5Z2a463gA")
    
    # Invalid cases
    check:
      # Invalid syntax: gibberish
      parseRootEntry("gibberish")
                    .error()
                    .contains("Invalid syntax")

      # Invalid syntax: no space
      parseRootEntry("enrtree-root:v1e=JWXYDBPXYWG6FX3GMDIBFA6CJ4 l=C7HRFPF3BLGF3YR4DY5KX3SMBE seq=1sig=o908WmNp7LibOfPsr4btQwatZJ5URBr2ZAuxvK4UWHlsB9sUOTJQaGAlLPVAhM__XJesCHxLISo94z5Z2a463gA")
                    .error()
                    .contains("Invalid syntax")
      
      # Invalid child: eroot too short
      parseRootEntry("enrtree-root:v1 e=JWXYDBPXYWG6FX3GMDIBFA6CJ l=C7HRFPF3BLGF3YR4DY5KX3SMBE seq=1 sig=o908WmNp7LibOfPsr4btQwatZJ5URBr2ZAuxvK4UWHlsB9sUOTJQaGAlLPVAhM__XJesCHxLISo94z5Z2a463gA")
                    .error()
                    .contains("Invalid child")
      
      # Invalid child: lroot newline
      parseRootEntry("enrtree-root:v1 e=JWXYDBPXYWG6FX3GMDIBFA6CJ4 l=C7HRFPF3BLGF3YR4DY5KX3SM\n\r seq=1 sig=o908WmNp7LibOfPsr4btQwatZJ5URBr2ZAuxvK4UWHlsB9sUOTJQaGAlLPVAhM__XJesCHxLISo94z5Z2a463gA")
                    .error()
                    .contains("Invalid child")
      
      # Invalid signature
      parseRootEntry("enrtree-root:v1 e=JWXYDBPXYWG6FX3GMDIBFA6CJ4 l=C7HRFPF3BLGF3YR4DY5KX3SMBE seq=1 sig=o908WmNp7LibOfPsr4btQwatZJ5URBr2ZAuxvK4UWHlsB9sUOTJQaGAlLPVAhM__XJesCHxLISo94z5Z2a463g")
                    .error()
                    .contains("Invalid signature")

  asyncTest "Parse branch entry":
    # Expected case
    let entryRes = parseBranchEntry("enrtree-branch:2XS2367YHAXJFGLZHVAWLQD4ZY,H4FHT4B454P6UXFD7JCYQ5PWDY,MHTDO6TMUBRIA2XWG5LUDACK24")
    
    check:
      entryRes.isOk()
      entryRes[].children.len == 3
      entryRes[].children.contains("2XS2367YHAXJFGLZHVAWLQD4ZY")
      entryRes[].children.contains("H4FHT4B454P6UXFD7JCYQ5PWDY")
      entryRes[].children.contains("MHTDO6TMUBRIA2XWG5LUDACK24")
    
    # Invalid cases
    check:
      # Invalid syntax: gibberish
      parseBranchEntry("gibberish")
                      .error()
                      .contains("Invalid syntax")
      
      # Invalid syntax: invalid space
      parseBranchEntry("enrtree-branch :2XS2367YHAXJFGLZHVAWLQD4ZY,H4FHT4B454P6UXFD7JCYQ5PWDY,MHTDO6TMUBRIA2XWG5LUDACK24")
                      .error()
                      .contains("Invalid syntax")

      # Invalid child: invalid first entry - leading space
      parseBranchEntry("enrtree-branch: 2XS2367YHAXJFGLZHVAWLQD4ZY,H4FHT4B454P6UXFD7JCYQ5PWDY,MHTDO6TMUBRIA2XWG5LUDACK24")
                      .error()
                      .contains("Invalid child")
      
      # Invalid child: invalid middle entry - too short
      parseBranchEntry("enrtree-branch:2XS2367YHAXJFGLZHVAWLQD4ZY,H4FHT4B454P6UXFD7JCYQ5PWD,MHTDO6TMUBRIA2XWG5LUDACK24")
                      .error()
                      .contains("Invalid child")

      # Invalid child: invalid last entry - trailing space
      parseBranchEntry("enrtree-branch:2XS2367YHAXJFGLZHVAWLQD4ZY,H4FHT4B454P6UXFD7JCYQ5PWDY,MHTDO6TMUBRIA2XWG5LUDACK24 ")
                      .error()
                      .contains("Invalid child")
