# Audit Permission Checks Component

This component compares your permissions of app according to referance branch. If any changes in related branch, user can break down workflow.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_CACHE_INCLUDED_PATHS`: Specifies the files and folders which should be in cache. Multiple glob patterns can be provided as a colon-separated list. For example; .gradle:app/build
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.
- `AC_CALLBACK_URL`: System generated callback url for signed url web service. Its value is different for various environments.


