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

  var gotoNextStep = false;

  try {
    print('Analyzing commit $sha...');

    // 1. Determine if it's a Framework or Engine commit
    var frameworkCommitSha = sha;
    DateTime? commitDate;

    try {
      final commit = await client.getCommit(_flutterRepo, sha);
      commitDate = CommitObject(
        commit['commit'] as Map<String, dynamic>,
      ).committerDate;
      print('Found Framework commit: $sha date: $commitDate');
      gotoNextStep = true; // Successfully found a framework commit
    } catch (e) {
      if (e is GitHubHttpException && e.statusCode == 404) {
        print('Commit not found in $_flutterRepo. Assuming Engine commit.');

        // Strategy: Find the Framework commit that rolled this Engine SHA.
        // We look for the commit that introduced this SHA in
        // bin/internal/engine.version.

        print('Searching for engine roll commit for $sha...');

        // 1. List commits that touched engine.version
        // We might need to page this if it's old.
        var page = 1;
        // To store the earliest framework commit that contains the engine SHA
        String? earliestMatchingFrameworkCommitSha;
        DateTime? earliestMatchingCommitDate; // To store its date

        // Limit to 5 pages (~150 commits) to save quota.
        // Commits are returned in reverse chronological order (newest first).
        while (page <= 5) {
          final commits = await client.getCommits(
            _flutterRepo,
            path: 'bin/internal/engine.version',
            page: page,
          );
          if (commits.isEmpty) break; // No more commits or end of history

          for (var commitMap in commits) {
            final cSha = commitMap['sha'] as String;

            try {
              final content = await client.getFileContent(
                _flutterRepo,
                'bin/internal/engine.version',
                cSha,
              );
              if (content.trim() == sha) {
                // This commit contains the target engine SHA.
                // Since we're iterating new-to-old, this is a candidate for the
                // earliest.
                earliestMatchingFrameworkCommitSha = cSha;
                earliestMatchingCommitDate = CommitObject(
                  commitMap['commit'] as Map<String, dynamic>,
                ).committerDate;
                // Continue iterating to find an even older one (if any in this
                // page or next)
              } else {
                // This commit does NOT contain the target engine SHA.
                // If we previously found a match, then the
                // 'earliestMatchingFrameworkCommitSha'
                // we currently hold is the roll commit (the one just before
                // this non-match).
                if (earliestMatchingFrameworkCommitSha != null) {
                  frameworkCommitSha = earliestMatchingFrameworkCommitSha;
                  commitDate = earliestMatchingCommitDate!;
                  print(
                    'Found engine roll commit: '
                    '$frameworkCommitSha (date: $commitDate)',
                  );
                  gotoNextStep = true;
                  break; // Found the roll commit, exit inner loop
                }
                // If no match was found yet, just continue to the next commit.
              }
            } catch (err) {
              print('Warning: Error checking content for $cSha: $err');
              // Continue to next commit if there's an error with this one
            }
          }
          if (gotoNextStep) break; // Found the roll commit, exit outer loop
          page++;
        }

        if (!gotoNextStep) {
          // If we reached here, either no roll commit was found in the history
          // checked, or the engine SHA is present in all checked commits
          // (meaning it's very old).
          if (earliestMatchingFrameworkCommitSha != null) {
            // We found at least one match, but didn't find a preceding
            // non-match.
            // This means the earliest match we found is the best we can do
            // within the search depth.
            frameworkCommitSha = earliestMatchingFrameworkCommitSha;
            commitDate = earliestMatchingCommitDate!;
            print(
              'Warning: Could not find the exact introduction point for '
              'engine SHA $sha in recent history.',
            );
            print(
              'Using the earliest matching framework commit found: '
              '$frameworkCommitSha (date: $commitDate)',
            );
            gotoNextStep = true;
          } else {
            // No match found at all within the search depth.
            print(
              'Error: Could not find engine roll for $sha in recent history of $_flutterRepo/bin/internal/engine.version.',
            );
            exitCode = ExitCode.dataErr;
            return;
          }
        }
      } else {
        rethrow;
      }
    }

    if (!gotoNextStep) {
      // This should ideally not be reached if the above logic is exhaustive,
      // but as a safeguard if `gotoNextStep` wasn't set.
      print('Error: Failed to determine framework commit for $sha.');
      exitCode = ExitCode.software;
      return;
    }

    if (commitDate == null) {
      print('Could not determine commit date.');
      exitCode = ExitCode.dataErr;
      return;
    }

    // 2. Fetch all tags
    print('Fetching tags...');

    // 3. Filter and Sort tags
    final validTags = <Version, String>{};
    await for (var tag in client.getAllTags(_flutterRepo)) {
      try {
        final tagMap = tag;
        var name = tagMap['name'] as String;
        if (name.startsWith('v')) name = name.substring(1);
        final version = Version.parse(name);
        validTags[version] =
            (tagMap['commit'] as Map<String, dynamic>)['sha'] as String;
      } catch (_) {}
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
        final midDate = CommitObject(
          midCommit['commit'] as Map<String, dynamic>,
        ).committerDate;

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

    print('\nNo tag found containing commit $sha');
  } finally {
    client.close();
  }
}
