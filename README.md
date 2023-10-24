# Audit Permission Checks Component

This component compares your permissions of app according to referance branch. If any changes in related branch, user can break down workflow.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_CACHE_INCLUDED_PATHS`: Specifies the files and folders which should be in cache. Multiple glob patterns can be provided as a colon-separated list. For example; .gradle:app/build
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.
- `AC_CALLBACK_URL`: System generated callback url for signed url web service. Its value is different for various environments.

Optional Input Variables

- `AC_REPOSITORY_DIR`: Cloned git repository path. Included and excluded paths are defined relative to cloned repository, except `~/`, `/` or environment variable prefixed paths. See following sections for more details.

## Included & Excluded Paths

Cache step uses a pattern in order to select files and folders. That the pattern is not a regexp, it's closer to a shell glob. (_The verb "glob" is an old Unix term for filename matching in a shell._)

Also we have some keywords or characters for special use cases, especially for system folders. Following sections summarize cache step's supported patterns for included and excluded paths.

### System vs. Repository

In order to identify between a repository resource and a system resource, cache step checks prefix for each given pattern.

Resource word, used in the document, means files or folders in this context.

Repository resources begin with directly glob pattern. They shouldn't be prefixed with `/` or other folder tree characters.

