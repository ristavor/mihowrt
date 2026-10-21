# Generator goldens

Captured in the Alpine test container from the inline generator at commit
`206c4a6bb0511a3200c9b9e49385b2d72016bb95`, before the module/awk split.

`tests/test_mihomo_config.sh` compares each successful generator invocation's
runtime YAML and `.profile` byte-for-byte against these files. The filename
number is the invocation's position in that test, including calls made by
`profile_ensure`. Rejected flow-style inputs occupy positions 3 and 16, so
those positions have no output files. There are 40 successful output pairs.

The test's temporary directory stores the invocation counter so calls from
subshells share the same sequence. Expected flow-style rejection is still
checked by the existing assertions; there is no runtime output to snapshot.
