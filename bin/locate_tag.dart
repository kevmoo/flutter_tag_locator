import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_tag_locator/src/commit_object.dart';
import 'package:flutter_tag_locator/src/exit_code.dart';
import 'package:flutter_tag_locator/src/github_client.dart';
import 'package:pub_semver/pub_semver.dart';

const _flutterRepo = 'flutter/flutter';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('sha', abbr: 's', help: 'The commit SHA to look for.')
    ..addOption('token', abbr: 't', help: 'GitHub API token (optional).');

  final argResults = parser.parse(arguments);
  final sha = argResults['sha'] as String?;
  final token =
      argResults['token'] as String? ??
      Platform.environment['GITHUB_TOKEN'] ??
      Platform.environment['HOMEBREW_GITHUB_API_TOKEN'];

  if (sha == null) {
    print('Error: --sha is required.');
    print(parser.usage);
    exitCode = ExitCode.usage;
    return;
  }

  final client = GitHubClient(token);

  try {
    print('Analyzing ENGINE commit $sha');

    // 1. Determine if it's a Framework or Engine commit
    var frameworkCommitSha = sha;
    final commit = await client.getCommit(_flutterRepo, sha);
    final commitDate = commit.committerDate;
    print('Found Framework commit: $sha\n\tdate: $commitDate');
    // Successfully found a framework commit

    // 2. Fetch all tags
    print('Fetching tags...');

    // 3. Filter and Sort tags
    final validTags = <Version, String>{};
    await for (var tag in client.getAllTags(_flutterRepo)) {
      var name = tag['name'] as String;
      if (name.startsWith('v')) name = name.substring(1);
      try {
        final version = Version.parse(name);
        validTags[version] = CommitObject.extract(tag).sha;
      } on FormatException {
        // Ignore invalid version tags
      }
    }

    final sortedVersions = validTags.keys.toList()..sort();
    print('Sorted ${sortedVersions.length} versions.');

    // Optimization: Filter out tags that are definitely too old based on date.
    // We can't check every tag's date (too many requests).
    // But we can binary search or sample to find a lower bound.
    // Assumption: Version numbers roughly correlate with time.
    // We want to find the first version where date >= commitDate.
    // Note: This is not strictly monotonic for patch releases, but good for
    // finding the "oldest" tag which is usually a pre-release or stable on the
    // main line.

    var startIndex = 0;
    var endIndex = sortedVersions.length - 1;
    var lowerBound = 0;

    print('Narrowing down search range...');

    // Check middle.
    while (startIndex <= endIndex) {
      final mid = (startIndex + endIndex) ~/ 2;
      final midVersion = sortedVersions[mid];
      final midSha = validTags[midVersion]!;

      try {
        final midCommit = await client.getCommit(_flutterRepo, midSha);
        final midDate = midCommit.committerDate;

        if (midDate.isBefore(commitDate)) {
          // This tag is older than our commit. The target tag must be after
          // this.
          // Store this as a possible lower bound (plus one)
          lowerBound = mid + 1;
          startIndex = mid + 1;
        } else {
          // This tag is newer (or same). The target could be this or earlier.
          endIndex = mid - 1;
        }
      } catch (e) {
        // If we hit rate limit here, we are in trouble.
        print('Warning: Could not fetch date for $midVersion: $e');
        break;
      }
    }

    // Safety buffer: back up a bit in case of out-of-order releases
    // (cherry-picks)
    lowerBound = (lowerBound - 10).clamp(0, sortedVersions.length - 1);

    print(
      'Starting search from version '
      '${sortedVersions[lowerBound]} (Index $lowerBound)',
    );

    for (var i = lowerBound; i < sortedVersions.length; i++) {
      final version = sortedVersions[i];
      final tagSha = validTags[version]!;

      // Check if frameworkCommitSha is an ancestor of tagSha
      try {
        final isAncestor = await client.isAncestor(
          _flutterRepo,
          frameworkCommitSha,
          tagSha,
        );

        if (isAncestor) {
          print('\nFound oldest tag: $version');
          print('Tag Commit: $tagSha');
          print(
            'Release URL: https://github.com/$_flutterRepo/releases/tag/${version.toString()}',
          );

          print('\n\n$sha, $version, $tagSha, $commitDate');
          exitCode = 0;
          return;
        }
        stdout.write('.');
      } catch (e) {
        if (e.toString().contains('Rate Limit')) {
          print('\nRate limit hit. Try providing a GitHub token with --token.');
          exitCode = ExitCode.tempFail;
          return;
        }
        stdout.write('x');
      }
    }

    print('\nNo tag found containing FRAMEWORK commit $sha');
  } finally {
    client.close();
  }
}
