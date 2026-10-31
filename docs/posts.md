---
layout: page
title: posts
permalink: /posts/
---

{% for post in site.posts %}* {{ post.date | date: site.minima.date_format }} [{{ post.title }}]({{ post.url | relative_url }}){% if post.description %}: {{ post.description }}{% endif %}
{% endfor %}
[RSS]({{ "/feed.xml" | relative_url }})
