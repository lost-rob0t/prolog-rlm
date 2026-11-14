/* Remote topology: Forgejo canonical + GitHub mirror.
   Verified 2026-09-11 while syncing github issues/PRs/worktrees (run-51d2530). */

remote_origin_forgejo('ssh://forgejo@git.starintel.actor:22/nsaspy/prolog-rlm.git').
remote_mirror_github('git@github.com:lost-rob0t/prolog-rlm.git').

% The two remotes have independent PR numbering universes.
% Merge commits in main's history cite Forgejo PR numbers, not GitHub numbers.
pr_numbering_universe(forgejo, origin).
pr_numbering_universe(github, github).

% github/main history was at some point replaced by the Forgejo-mirrored
% history. GitHub-side merge commits of pre-mirror GitHub PRs vanished from
% history while those PRs still show MERGED on GitHub.
% Symptom: a GitHub PR is MERGED but `git merge-base --is-ancestor <branch> main`
% fails. Before treating the branch as "lost work", check patch equivalence:
%   git cherry main <branch>   ->  '-' means content already in main.
github_merged_prs_lost_from_history([150, 314, 316, 324]).
% Confirmed re-landed via patch-equivalence in main for the above.
% Exception that was NOT patch-equivalent (lost content):
%   PR 368 icon-add, commit 0566530; re-landed as e62ac3b / fix/reland-icon-368 / PR 419.
lost_patch_recovered(pr_368, 'e62ac3b via fix/reland-icon-368, PR 419').

% Stale-open hazard: a mirrored branch can be merged into canonical main while
% its GitHub PR remains OPEN (observed PR 360, closed 2026-09-11).
% Check before trusting open-PR state:
%   git branch -r --contains <pr-head-tip> | grep github/main
stale_open_pr_symptom(pr_360, 'head tip already in main, PR left open with UNSTABLE merge state').

% Safe-sync rule distilled:
% before removing a worktree for a closed item, require either
% fully merged into canonical main OR patch-equivalent (git cherry '-');
% never rely on the GitHub MERGED badge alone (see replaced-mirror history).
worktree_removal_precondition(merged_into_canonical_main).
worktree_removal_precondition(patch_equivalent_in_main).