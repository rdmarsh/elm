# Website Examples

Queries relating to websites, website groups, and website properties.

**See also:**
- [devices.md](devices.md) for similar property-filtering patterns on devices
- [alerts.md](alerts.md) for website alert and SDT queries

<!--ts-->
   * [Find websites with no properties in a group hierarchy](#find-websites-with-no-properties-in-a-group-hierarchy)
   * [Find websites missing required properties](#find-websites-missing-required-properties)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->

<!--te-->

## Find websites with no properties in a group hierarchy

The LM API filter does not support OR across multiple group IDs, so this is
done in two passes. First, use the API-side filter to collect all group IDs
whose `fullPath` is under the target group (catching subgroups at any depth).
Then filter `WebsiteList` client-side for both group membership and empty
properties. jq is needed to reshape the IDs into an array for the second step.

```shell
gids=$(elm WebsiteGroupList -s0 -f id -F fullPath\~"acme/" | \
  jq '[.WebsiteGroupList[].id]')

elm WebsiteList -s0 -f name,domain,groupId,properties | \
  jq --argjson gids "$gids" \
    '.WebsiteList[] | select((.groupId as $g | $gids | contains([$g])) and (.properties | length == 0)) | {name, domain, groupId}'
```

## Find websites missing required properties

Extending the above, this checks that every website in the group hierarchy has
a specific set of required properties set to a non-empty value. Any website
missing one or more is reported along with the list of what is missing.

```shell
gids=$(elm WebsiteGroupList -s0 -f id -F fullPath\~"acme/" | \
  jq '[.WebsiteGroupList[].id]')

elm WebsiteList -s0 -f name,domain,groupId,properties | \
  jq --argjson gids "$gids" '
    ["host", "acme.grok.event.destination", "acme.company.sys_id", "acme.ci.sys_id"] as $required |
    .WebsiteList[] |
    select(.groupId as $g | $gids | contains([$g])) |
    . as $site |
    ($site.properties | map(select(.value != "")) | map(.name)) as $present |
    ($required - $present) as $missing |
    select($missing | length > 0) |
    {name: $site.name, domain: $site.domain, missing: $missing}
  '
```

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header examples/websites.md
```
