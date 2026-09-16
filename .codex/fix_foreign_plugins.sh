#!/usr/bin/env bash
# Patch OTHER plugins in redmine/plugins/ so a full multi-plugin install BOOTS.
#
# --- WHAT THIS IS AND IS NOT ---
#
# It is a TEST-ENVIRONMENT helper for the integration run described in CONTRIBUTING.md:
# "does this plugin still work when every other plugin the operator runs is installed
# too". Nothing here ships, nothing here is required to use this plugin, and it must never
# be invoked by `test_plugin.sh` — a suite that silently rewrites third-party code is a
# suite whose green means nothing about the code the operator actually has.
#
# It is NOT a fork and NOT a fix for those plugins' users. Every hunk is one line or two,
# each is commented in place with what it repairs, and each is a candidate for a pull
# request to the plugin that owns it. `docs/plan/HANDOVER.md` §2b holds the reasoning.
#
# Every fix below is a BOOT BLOCKER: without it Redmine does not start, or a page 500s for
# everybody. Behavioural collisions between plugins (a global I18n transliterate rule, a
# globally registered Liquid filter) are deliberately NOT patched — those are findings to
# report, not other people's decisions to overrule.
#
# Measured 2026-08-21 against Redmine 7.0-stable / Rails 8.1.3.1 with 42 plugins installed.
#
# Usage:  .codex/fix_foreign_plugins.sh [redmine_dir]
set -u

REDMINE_DIR="${1:-${REDMINE_DIR:-redmine}}"
P="$(cd "$REDMINE_DIR/plugins" && pwd)"
say() { printf '  %-34s %s\n' "$1" "$2"; }

# --------------------------------------------------------------------- 1. bundler
# activesupport pinned below Rails 8 means Redmine 7.0 cannot `bundle install` AT ALL —
# not "that plugin is unavailable", the whole application refuses to resolve.
f="$P/redmine_itil_priority/Gemfile"
if [ -f "$f" ] && grep -q "activesupport', '>= 6.1', '< 8.0'" "$f"; then
  sed -i "s/gem 'activesupport', '>= 6.1', '< 8.0'/gem 'activesupport', '>= 6.1', '< 9.0'/" "$f"
  say redmine_itil_priority "Gemfile: activesupport '< 8.0' -> '< 9.0'"
fi

# --------------------------------------------------------------------- 2. plugin identity
# The id a plugin REGISTERS must equal its directory name, and three repositories are
# named differently from what they register. Redmine refuses to boot on the mismatch.
for pair in bless-this-redmine-sso:bless_this_redmine_sso \
            redmine_plugin_computed_custom_field:computed_custom_field \
            redmine_tags:redmineup_tags; do
  from="${pair%%:*}"; to="${pair##*:}"
  if [ -d "$P/$from" ] && [ ! -d "$P/$to" ]; then
    mv "$P/$from" "$P/$to" && say "$from" "installed as '$to' (its registered id)"
  fi
done

# --------------------------------------------------------------------- 3. removed Rails API
# `unloadable` left ActiveSupport in Rails 5.1. Each of these is a NoMethodError at load.
find "$P/redmine_subtask" "$P/redmine_ldap_sync" "$P/redmine_more_previews" \
     -name '*.rb' -type f 2>/dev/null | while read -r f; do
  grep -qE '^[[:space:]]*unloadable[[:space:]]*$' "$f" || continue
  sed -i -E 's/^([[:space:]]*)unloadable[[:space:]]*$/\1# PATCHED: removed from ActiveSupport in Rails 5.1\n\1# unloadable/' "$f"
  say "${f#"$P"/}" "unloadable commented out"
done

# `Redmine::WikiFormatting::Textile::Formatter::RULES` is gone in 7.0; this plugin pushes
# onto it at load time. Guarded rather than deleted, so 5.1/6.x keep the feature.
f="$P/redmine_wiki_extensions/lib/wiki_extensions_formatter_patch.rb"
if [ -f "$f" ] && grep -q "^  Redmine::WikiFormatting::Textile::Formatter::RULES << :inline_smiles" "$f"; then
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = s.replace("  Redmine::WikiFormatting::Textile::Formatter::RULES << :inline_smiles\n",
"""  # PATCHED: the RULES constant does not exist on Redmine 7.0 (the textile formatter was
  # reworked). Pushing onto it is a NameError that takes the whole application down.
  if defined?(Redmine::WikiFormatting::Textile::Formatter::RULES)
    Redmine::WikiFormatting::Textile::Formatter::RULES << :inline_smiles
  end
""", 1)
open(p, 'w', encoding='utf-8').write(s)
PY
  say redmine_wiki_extensions "guard Textile::Formatter::RULES (gone in 7.0)"
fi

# --------------------------------------------------------------------- 4. Zeitwerk
# The constant must match the file name. The CLASS is renamed and not the file, because the
# plugin's own lib requires that exact path, and a hook listener is found by subclassing.
f="$P/redmine_helpdesk_contact_sync/lib/redmine_helpdesk_contact_sync/hooks/view_layouts_hook.rb"
if [ -f "$f" ] && grep -q "class ViewsLayoutsHook" "$f"; then
  sed -i 's/class ViewsLayoutsHook/class ViewLayoutsHook/' "$f"
  say redmine_helpdesk_contact_sync "ViewsLayoutsHook -> ViewLayoutsHook"
fi

# --------------------------------------------------------------------- 5. routing
# A route NAME the redmineup gem has claimed for itself since 1.1.x. Two definitions is
# `ArgumentError: Invalid route name, already in use` and no boot.
f="$P/redmine_contacts/config/routes.rb"
if [ -f "$f" ] && grep -qE "^\s*match 'auto_completes/taggable_tags'" "$f"; then
  sed -i -E "s|^(\s*)(match 'auto_completes/taggable_tags'.*)$|\1# PATCHED: the redmineup gem defines this route name itself.\n\1# \2|" "$f"
  say redmine_contacts "drop duplicate auto_complete_taggable_tags route"
fi

# Rails 8.1 takes ONE action per `get`/`post`/... inside a resource block. Redmine reports
# several as "the routes definition of <plugin> could not be loaded", with no line number.
python3 - "$P"/*/config/routes.rb <<'PY'
import re, sys
VERB = re.compile(r'^(\s*)(get|post|put|patch|delete)\s+((?::[a-z_0-9]+\s*,\s*)+:[a-z_0-9]+)\s*$')
for path in sys.argv[1:]:
    out, hit = [], False
    for line in open(path, encoding='utf-8').read().split('\n'):
        m = VERB.match(line)
        if not m:
            out.append(line); continue
        indent, verb, syms = m.groups()
        names = [s.strip() for s in syms.split(',')]
        out.append(f'{indent}# PATCHED for Rails 8.1: one action per call '
                   f'("Wrong number of arguments (expect 1, got {len(names)})").')
        out.extend(f'{indent}{verb} {n}' for n in names)
        hit = True
    if hit:
        open(path, 'w', encoding='utf-8').write('\n'.join(out))
        print('  %-34s %s' % (path.split('plugins/')[-1].split('/')[0],
                              'split multi-action route calls'))
PY

# A controller given WITHOUT a leading slash resolves RELATIVELY to the controller handling
# the request. From any NAMESPACED controller — and plugins do namespace them, this one
# included — these generated `<namespace>/people` and raised UrlGenerationError out of
# `layouts/base.html.erb`, i.e. a 500 on every page of the namespaced plugin.
for f in "$P/redmine_people/lib/redmine_people/patches/application_helper_patch.rb" \
         "$P/redmine_people/lib/redmine_people/patches/avatars_helper_patch.rb"; do
  [ -f "$f" ] || continue
  if grep -qE ":controller => 'people'|controller: 'people'" "$f"; then
    sed -i "s/:controller => 'people'/:controller => '\/people'/g; s/controller: 'people'/controller: '\/people'/g" "$f"
    say "${f#"$P"/}" "controller 'people' -> '/people' (absolute)"
  fi
done

# --------------------------------------------------------------------- 6. patch ORDERING
# THE ONE FIX WORTH READING TWICE, because it is the failure this repository's own
# `patches/projects_helper_patch.rb` header is about, arriving from somebody else's code.
#
# `ProjectsHelper#project_settings_tabs` is alias-chained by eight plugins and PREPENDED by
# three. An alias chain installed after a prepend copies the prepended method into
# ProjectsHelper as its `_without_`, and that method's `super` then has nothing below it:
#
#     NoMethodError: super: no superclass method `project_settings_tabs'
#
# and the project settings page 500s for everybody. `redmine_ai_triage` prepends from
# init.rb and sorts before `redmine_questions`, `redmine_contacts` and the other chainers,
# so it landed on the wrong side of them. Deferring to `after_plugins_loaded` — the hook
# Redmine fires after every plugin's init.rb, in the same `to_prepare` — is the whole fix,
# and is what this plugin already does for the same reason.
f="$P/redmine_ai_triage/init.rb"
if [ -f "$f" ] && grep -qE "^RedmineAiTriage::Patches::ProjectsHelperPatch\.apply!" "$f"; then
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = s.replace("RedmineAiTriage::Patches::ProjectsHelperPatch.apply!",
"""# PATCHED: deferred to after_plugins_loaded. Prepending this method from init.rb puts it
# on the wrong side of the eight plugins that alias-chain it, and the next chain then
# captures this prepend as its `_without_`, leaving `super` with nowhere to go — a 500 on
# the project settings page for every user. See .codex/fix_foreign_plugins.sh §6.
class RedmineAiTriageProjectsHelperLoader < Redmine::Hook::Listener
  def after_plugins_loaded(_context = {})
    RedmineAiTriage::Patches::ProjectsHelperPatch.apply!
  end
end""", 1)
open(p, 'w', encoding='utf-8').write(s)
PY
  say redmine_ai_triage "ProjectsHelper prepend -> after_plugins_loaded"
fi

# --------------------------------------------------------------------- 7. NOT fixed here
# `redmine_datetime_custom_field` requires `redmine_base_deface`, which is in none of the
# account's repositories and could not be obtained from either of its known upstreams. It
# is EXCLUDED from the integration set rather than satisfied with a stub: faking a plugin
# registration to get past a dependency check is how a green run stops meaning anything.
if [ -d "$P/redmine_datetime_custom_field" ]; then
  say redmine_datetime_custom_field "NEEDS redmine_base_deface — exclude it, do not stub"
fi

echo "  done. Boot with: RAILS_ENV=test bundle exec rails runner 'puts Redmine::Plugin.all.size'"
