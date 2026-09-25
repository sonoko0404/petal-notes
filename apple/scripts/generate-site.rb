#!/usr/bin/env ruby
require 'cgi'
require 'fileutils'
root = File.expand_path('../..', __dir__)
%w[privacy support].each do |kind|
  %w[en zh-Hans].each do |lang|
    markdown = File.read(File.join(root, kind == 'privacy' ? "docs/legal/privacy-policy-#{lang}.md" : "docs/support/faq-#{lang}.md"))
    title, body = markdown.split("\n", 2)
    title = title.sub(/^# /, '')
    paragraphs = body.strip.split(/\n\n+/).map { |p| "<p>#{CGI.escapeHTML(p)}</p>" }.join("\n")
    other = lang == 'en' ? 'zh-Hans' : 'en'
    navigation = lang == 'en' ? ['Home','Privacy','Help'] : ['首页','隐私','帮助']
    html = <<~HTML
      <!doctype html>
      <html lang="#{lang}">
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark"><title>#{title} · Petal</title><link rel="stylesheet" href="../style.css"></head>
      <body><header><nav aria-label="#{lang == 'en' ? 'Navigation' : '导航'}"><a href="../index.html">#{navigation[0]}</a> <a href="../privacy/#{lang}.html">#{navigation[1]}</a> <a href="../support/#{lang}.html">#{navigation[2]}</a> <a href="#{other}.html" lang="#{other}" hreflang="#{other}">#{other == 'en' ? 'English' : '简体中文'}</a></nav></header>
      <main><h1>#{title}</h1>#{paragraphs}</main></body></html>
    HTML
    target = File.join(root, 'site', kind, "#{lang}.html")
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, html)
  end
end
