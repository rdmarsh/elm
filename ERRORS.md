# Errors

The following show some errors you may see and what they mean:

<!--ts-->
* [size limit is less than total records](#warning-size-limit-is-less-than-total-records)
* [no valid headings](#warning-no-valid-headings)
* [no data found](#warning-no-data-found)
<!--te-->

## Error: access_id, access_key or account_name not set via cli or config file

Missing the values needed to access the API from the cli or config file.
See `config.example.ini`

## Error: config file permissions are group or world readable

Permissions for the config file are either group or world readable. This
is enforced as these files can store api access ids or keys

To correct: `chmod 600 ~/.elm/config.ini`

## Warning: size limit is less than total records

There is a valid size limit option (`--size INTEGER`, defaults to 50),
but there are more results returned by the query that aren't displayed

## Error: no valid fields selected

None of the fields selected by the fields option (`--fields FIELD,...`)
are valid fields

## Warning: no data found

No data has been returned by the query
