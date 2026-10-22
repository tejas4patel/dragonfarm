# Writes docs/feed.xml: an RSS 2.0 feed of the site's blog-style articles,
# with each article's full text, for R-bloggers and feed readers. Run after
# pkgdown has built the site (the pkgdown workflow does this). R-bloggers
# needs full content, R-only posts, no base64 images, and absolute links.
#
# To publish a new post: add a row to `posts` (its article slug and the date
# it went out). Newest posts are listed first in the feed.

posts <- data.frame(
  slug = c("introducing-0-4-0", "fda-guidance", "model-sizes"),
  date = c("2026-10-16", "2026-10-16", "2026-10-15")
)

site <- "https://dragonfarm.dev/"
docs <- "docs"

absolute <- function(url, base) {
  if (is.na(url) || !nzchar(url) || grepl("^(https?:|mailto:|#|data:)", url)) return(url)
  xml2::url_absolute(url, base)
}

item <- function(slug, date) {
  path <- file.path(docs, "articles", paste0(slug, ".html"))
  if (!file.exists(path)) stop("Not built: ", path, call. = FALSE)
  page <- xml2::read_html(path)
  link <- paste0(site, "articles/", slug, ".html")
  title <- xml2::xml_text(xml2::xml_find_first(page, "//main//h1"))
  desc <- xml2::xml_attr(xml2::xml_find_first(page, "//meta[@name='description']"), "content")
  main <- xml2::xml_find_first(page, "//main")
  # The page header repeats the title (and the logo); the feed item has its own.
  xml2::xml_remove(xml2::xml_find_all(main, ".//div[contains(@class,'page-header')]"))
  # Heading anchors (#section links) would be dead links once the post is elsewhere.
  xml2::xml_remove(xml2::xml_find_all(main, ".//a[contains(@class,'anchor')]"))
  for (a in c("src", "href")) {
    nodes <- xml2::xml_find_all(main, sprintf(".//*[@%s]", a))
    for (n in nodes) xml2::xml_attr(n, a) <- absolute(xml2::xml_attr(n, a), link)
  }
  if (length(xml2::xml_find_all(main, ".//img[starts-with(@src,'data:')]"))) {
    stop("Embedded base64 image in ", slug, "; R-bloggers does not accept them.", call. = FALSE)
  }
  body <- paste(vapply(xml2::xml_children(main), as.character, ""), collapse = "\n")
  body <- gsub("]]>", "]]]]><![CDATA[>", body, fixed = TRUE)
  pub <- format(as.POSIXct(paste(date, "12:00:00"), tz = "UTC"), "%a, %d %b %Y %H:%M:%S +0000")
  esc <- function(x) gsub("<", "&lt;", gsub("&", "&amp;", x %||% "", fixed = TRUE), fixed = TRUE)
  sprintf(paste0("  <item>\n    <title>%s</title>\n    <link>%s</link>\n    <guid isPermaLink=\"true\">%s</guid>\n",
                 "    <pubDate>%s</pubDate>\n    <category>R</category>\n    <description>%s</description>\n",
                 "    <content:encoded><![CDATA[%s]]></content:encoded>\n  </item>"),
          esc(title), link, link, pub, esc(desc), body)
}

`%||%` <- function(x, y) if (is.null(x) || is.na(x)) y else x
posts <- posts[order(posts$date, decreasing = TRUE), ]
items <- vapply(seq_len(nrow(posts)), function(i) item(posts$slug[i], posts$date[i]), "")
latest <- format(as.POSIXct(paste(posts$date[1], "12:00:00"), tz = "UTC"), "%a, %d %b %Y %H:%M:%S +0000")
feed <- c(
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:atom="http://www.w3.org/2005/Atom">',
  "<channel>",
  "  <title>dragonfarm</title>",
  sprintf("  <link>%s</link>", site),
  sprintf('  <atom:link href="%sfeed.xml" rel="self" type="application/rss+xml"/>', site),
  "  <description>Raise your own dragon: fine-tune your own model on your documents, from R. Articles from the dragonfarm package.</description>",
  "  <language>en-gb</language>",
  sprintf("  <lastBuildDate>%s</lastBuildDate>", latest),
  items,
  "</channel>",
  "</rss>"
)
writeLines(feed, file.path(docs, "feed.xml"), useBytes = TRUE)
cat("Wrote", file.path(docs, "feed.xml"), "with", length(items), "posts\n")
