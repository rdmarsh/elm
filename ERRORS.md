# Errors

The following show some errors you may see and what they mean:

<!--ts-->
   * [Error: access_id, access_key or account_name not set via cli or config file](#error-access_id-access_key-or-account_name-not-set-via-cli-or-config-file)
   * [Error: config file permissions are group or world readable](#error-config-file-permissions-are-group-or-world-readable)
   * [Error: no valid fields selected](#error-no-valid-fields-selected)
   * [Warning: size limit is less than total records](#warning-size-limit-is-less-than-total-records)
   * [Warning: no data found](#warning-no-data-found)
   * [REST API error codes](#rest-api-error-codes)
   * [meta](#meta)

<!-- Created by https://github.com/ekalinin/github-markdown-toc -->
<!-- Added by: davidmarsh, at: Thu 14 Mar 2024 10:48:18 AEDT -->

<!--te-->

## Error: access_id, access_key or account_name not set via cli or config file

Missing the values needed to access the API from the cli or config file.
See `config.example.ini`

## Error: config file permissions are group or world readable

Permissions for the config file are either group or world readable. This
is enforced as these files can store api access ids or keys

To correct: `chmod 600 ~/.elm/config.ini`

## Error: no valid fields selected

None of the fields selected by the fields option (`--fields FIELD,...`)
are valid fields

## Warning: size limit is less than total records

There is a valid size limit option (`--size INTEGER`, defaults to 50),
but there are more results returned by the query that aren't displayed

## Warning: no data found

No data has been returned by the query

## REST API error codes

These are some error codes you may see from LM:

https://www.logicmonitor.com/support/api-error-codes

| Error Code | Error Message                                           |
| ---:       | ---                                                     |
| 100        | Continuing ...                                          |
| 403        | Authentication failed / Session timeout                 |
| 500        | Internal error                                          |
| 503        | Company is deactive                                     |
| 600        | The record already exists                               |
| 1000       | Server is busy                                          |
| 1001       | Internal error / Unknown error                          |
| 1007       | Bad request                                             |
| 1031       | There is a syntax error in the appliesTo field.         |
| 1040       | Cannot import LogicModule                               |
| 1041       | Permission denied                                       |
| 1058       | No such widget                                          |
| 1065       | No such company                                         |
| 1069       | No such record                                          |
| 1073       | The collector isn’t active                              |
| 1074       | Report too large                                        |
| 1075       | The request entity/report is too large                  |
| 1076       | Template too large                                      |
| 1077       | Invalid Macros / Bad request                            |
| 1078       | Please upload a .docx file                              |
| 1079       | The report template could not be uploaded               |
| 1091       | Rate exceed                                             |
| 1100       | Too many requests                                       |
| 1101       | Query timed out                                         |
| 1104       | Resource Dependency                                     |
| 1201       | Partial success /  The update was partially successful  |
| 1202       | The task is running                                     |
| 1204       | No Content                                              |
| 1301       | Save failed                                             |
| 1303       | All Locations are disable / No valid locations selected |
| 1313       | Report in progress                                      |
| 1400       | Bad request                                             |
| 1401       | Authentication failed                                   |
| 1403       | Permission denied                                       |
| 1404       | No such record                                          |
| 1409       | The record already exists                               |
| 1412       | The supplied precondition evaluated to false            |
| 1413       | The request entity is too large                         |
| 1500       | Internal error                                          |
| 14001      | Resource Dependency                                     |
| 14002      | Partial success                                         |
| 14003      | Properties must start with a letter to be valid.        |
| 14004      | Error in query string parameters                        |
| 14042      | No Such Company                                         |

## meta

Update the ToC on this page by running the following:

```shell
gh-md-toc --insert --no-backup --skip-header ERRORS.md
```

