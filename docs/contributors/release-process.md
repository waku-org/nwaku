# Release Process

How to do releases.

For more context, see https://trunkbaseddevelopment.com/branch-for-release/

## How to to do releases

1. Checkout a release branch from master

`git checkout -b release/v0.1`

2. Update `CHANGELOG.md` and ensure it is up to date

3. Create a tag with the same name as release and push it

```
git tag -as v0.1 -m "Initial release."
git push origin v0.1
```

4. Open a PR

5. Harden release in release branch

6. Modify tag

If you need to update stuff, remove tag and make sure the new tag is associated
with CHANGELOG update.

```
# Delete tag
git tag -d v0.1
git push --delete origin v0.1

# Make changes, rebase and tag again
# Squash to one commit and make a nice commit message
git rebase -i origin/master
git tag -as v0.1 -m "Initial release."
git push origin v0.1
```
