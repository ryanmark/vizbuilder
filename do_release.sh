#!/bin/bash

if ! git diff-index --quiet HEAD --; then
  echo You must commit all your changes before updating the version
  exit 1
fi

old_version=$(cat VERSION)

if [ $# -ne 1 ]; then
  read -p "Current version is $old_version. Enter a new version: " version
else
  version=$1
fi

if [ "$old_version" = "$version" ]; then
  echo Already at version $version
  exit 1
fi

echo Updating version to $version

echo $version > VERSION

read -p "Do you wish to commit the new version, tag and push? [y/N] " tyn
if echo "$tyn" | grep -iq "^y"; then
  git commit -am "bump to $version" && git tag v$version && git push && git push --tags

  read -p "Do you wish to build and publish the release? [y/N] " pyn
  if echo "$pyn" | grep -iq "^y"; then
    rm *.gem
    gem build vizbuilder.gemspec
    gem push *.gem
  fi
fi
