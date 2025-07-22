# gh-notify
gh-notify checks the GitHub Action's progress periodically and send you a notification when it's done.

# How to Use
# Prerequisites
You need those command installed on your machine:
- gh
- notify-send

Currently, gh-notify only supports linux.

# Installation
You can git clone this repo and build it with zig. You need zig v0.14.1 installed.

# Usage
You have to run the command inside the repository where the GitHub Action exists.

The command takes the run id as an argument:
```
$ gh-notify 16447760161
```
This output will look like below and send the notification when the run is finished.
```
$ gh-notify 16447760161
Run ID: 16447760161
Action's URL: https://github.com/karintomania/gh-notify/actions/runs/16447760161

[15:52] ⏳ Still running Automated Tests...
[15:53] ⏳ Still running Automated Tests...
[15:54] ⏳ Still running Automated Tests...
[15:55] ⏳ Still running Automated Tests...
[15:56] ✅ Task completed with success, Workflow Name: Automated Tests

You can see the result here: https://github.com/karintomania/gh-notify/actions/runs/16447760161
```
