vim9script noclear

if exists('loaded') | finish | endif
var loaded = true

# TODO:
# Maybe we should consider removing the concept of a default session.
# We never use it, and it adds some complexity to the plugin.

# TODO:
# Maybe add a  command opening a buffer  showing all session names  with a short
# description.
# When you would select one, you would have a longer description in a popup window.

# TODO:
# When Vim  starts, we could  tell the plugin to  look for a  `session.vim` file
# inside the working  directory, and source it  if it finds one, then  use it to
# track the session.
# This would allow us to not have to name all our sessions.
# Also, `:STrack ∅` should save & track the current session in `:pwd`/session.vim.
# Update: Wait.  How would we pause the tracking of a session then?
# I guess it would  need to check whether a session is  being tracked (easy), or
# has been tracked in the past (tricky?)...

# Autocmds {{{1

var read_stdin: bool
augroup MySession | autocmd!
    autocmd StdinReadPost * read_stdin = true

    #                    ┌ necessary to source ftplugins (trigger autocmds listening to BufReadPost?)
    #                    │
    autocmd VimEnter * ++nested LoadSessionOnVimenter()

    # Purpose of the next 3 autocmds: {{{
    #
    #    1. automatically save the current session, as soon as `g:my_session`
    #       pops into existence
    #
    #    2. update the session file frequently, and as long as `g:my_session` exists
    #       IOW, track the session
    #}}}
    #                     ┌ if sth goes wrong, the function returns the string:
    #                     │      'echoerr '.string(v:exception)
    #                     │
    #                     │ we need to execute this string
    #                     │
    autocmd BufWinEnter * execute Track()
    #       │
    #       └ We don't want the session to be saved only when we quit Vim,
    #         because Vim could exit abnormally.
    #
    #         Contrary to `BufEnter`, `BufWinEnter` is NOT fired for `:split`
    #         (without arguments), nor for `:split file`, `file` being already
    #         displayed in a window.
    #
    #         But most of the time, Vim won't quit abnormally, and the last saved
    #         state of our session will be performed when `VimLeavePre` is fired.
    #         So, `VimLeavePre` will have the final say most of the time.

    autocmd TabClosed * timer_start(0, (_) => execute('execute Track()') )
    # We also save whenever we close a tabpage, because we don't want
    # a closed tabpage to be restored while we switch back and forth between
    # 2 sessions with `:SLoad`.
    # But, we can't  save the session immediately, because for  some reason, Vim
    # would only save the last tabpage (or  the current one?).  So, we delay the
    # saving.

    # Why inspecting `v:servername`?{{{
    #
    # To not overwrite the `session/last` file if we're editing it outside a session.
    # We sometimes need to do this to debug some issue.
    #}}}
    # TODO: Why `MY_LAST_SESSION` is in uppercase?{{{
    #
    # To save it in viminfo? But we don't need it, since we use `session/last`, right?
    #
    # ---
    #
    # Same question for `MY_PENULTIMATE_SESSION`.
    #
    # ---
    #
    # If we don't need uppercase names,  write them in lowercase, and remove the
    # next `v:servername != ''` condition.
    #}}}
    autocmd VimLeavePre * execute Track(true)
        | if get(g:, 'MY_LAST_SESSION', '') != '' && v:servername != ''
        |     writefile([g:MY_LAST_SESSION], $HOME .. '/.vim/session/last')
        | endif
    autocmd User MyFlags statusline#hoist('global',
        \ '%{session#status()}', 5, expand('<sfile>:p') .. ':' .. expand('<sflnum>'))
augroup END

# Commands {{{1

# Why `execute HandleSession()` {{{
# and why `execute Track()`?
#
# If an error occurs in a function, we'll get an error such as:
#
#     Error detected while processing function <SNR>42_Track:˜
#     line   19:˜
#     Vim:E492: Not an editor command:             abcd˜
#
# We want our  `:STrack` command, and our autocmd, to  produce a message similar
# to a regular  Ex command.  We don't  want the detail of  the implementation to
# leak.
#
# By using `execute function()`, we can get an error message such as:
#
#     Error detected while processing BufWinEnter Auto commands for "*":˜
#     Vim:E492: Not an editor command:             abcd˜
#
# How does it work?
# When an error may occur, we capture it and convert it into a string:
#
#     try
#         ...
#     catch
#         return 'echoerr ' .. string(v:exception)
#     endtry
#
# We execute this string in the context of `:STrack`, or of the autocmd.
# Basically, the try conditional + `execute function()` is a mechanism which lets us
# choose the context in which an error may occur.
# Note, however, that in this case, it prevents our `:WTF` command from capturing
# the error, because it will happen outside of a function.
#}}}

# We use `:echoerr` for `:SDelete`, `:SRename`, `:SClose`, because we want the
# command to disappear if no error occurs during its execution.
# For `:SLoad` and `:STrack`, we use `:execute` because there will always be
# a message to display; even when everything works fine.
command -bar                                           SClose Close()
command -bar -nargs=? -complete=custom,SuggestSessions SDelete Delete(<q-args>)
command -bar -nargs=1 -complete=custom,SuggestSessions SRename Rename(<q-args>)

command -bar       -nargs=? -complete=custom,SuggestSessions SLoad Load(<q-args>)
command -bar -bang -nargs=? -complete=file                   STrack HandleSession(<bang>0, <q-args>)

# Functions {{{1
def Close() #{{{2
    if !exists('g:my_session')
        return
    endif
    silent STrack
    silent tabonly | silent only | enew
    RenameTmuxWindow('vim')
enddef

def Delete(session: string) #{{{2
    var session_to_delete: string
    if session == '%%'
        if exists('g:MY_PENULTIMATE_SESSION')
            session_to_delete = g:MY_PENULTIMATE_SESSION
        else
            Error('No alternate session to delete')
            return
        endif
    else
        session_to_delete = session == ''
            ? get(g:, 'my_session', get(g:, 'MY_LAST_SESSION', ''))
            : fnamemodify(SESSION_DIR .. '/' .. session .. '.vim', ':p')
    endif

    if session_to_delete == get(g:, 'MY_PENULTIMATE_SESSION', '')
        unlet! g:MY_PENULTIMATE_SESSION
    elseif session_to_delete == get(g:, 'my_session', '')
        if exists('g:MY_PENULTIMATE_SESSION')
            # We  have  to load  the  alternate  session *before*  deleting  the
            # session file, because `:SLoad %%` will take a last snapshot of the
            # current session, which would restore the deleted file.
            SLoad %%
            # The current session has just become the alternate one.
            # Since we're going to delete its file, make the plugin forget about it.
            unlet! g:MY_PENULTIMATE_SESSION
        else
            SClose
        endif
    endif

    # Delete the session file, and if sth goes wrong report what happened.
    if delete(session_to_delete) == -1
        Error('Failed to delete ' .. session_to_delete)
        return
    endif
    echo string(session_to_delete .. ' has been deleted')
enddef

def HandleSession(arg_bang: bool, arg_file: string) #{{{2
    bang = arg_bang
    sfile = arg_file
    # `last_used_session` is used by:{{{
    #
    #    - SessionPause()
    #    - SessionDelete()
    #    - WhereDoWeSave()
    #
    # It's useful to be able to  delete a session which isn't currently tracked,
    # and to track the session using the session file of the last session used.
    #}}}
    last_used_session = get(g:, 'my_session', v:this_session)

    try
        # `:STrack` should behave mostly like `:mksession` with the additional benefit of updating the session file.{{{
        #
        # However, we want 2 additional features:  pause/resume and deletion.
        #
        #     :STrack     pause/resume
        #     :STrack!    delete
        #}}}
        if ShouldPauseSession()
            SessionPause()
            return
        elseif ShouldDeleteSession()
            SessionDelete()
            return
        endif

        sfile = WhereDoWeSave()
        if sfile == ''
            return
        endif

        # Don't overwrite an existing session file by accident.{{{
        #
        # Unless a bang is given.
        # Or unless `:STrack` was run without argument (in which case we want to
        # resume the tracking of a paused session).
        #}}}
        # Why `filereadable()`?{{{
        #
        # Well, we want  to prevent overwriting an existing session  file, so it
        # makes sense to check that the file does exist.
        #
        # Besides, if you  don't, then if you run `:STrack  foo`, while there is
        # no  `foo.vim` session  file, Vim  will just  run `:mksession`,  but it
        # won't set `g:my_session`, nor will it call `Track()`.
        #
        # IOW, you'll create a regular session file, which won't be tracked.
        #}}}
        if !bang && arg_file != '' && filereadable(sfile)
            execute 'mksession ' .. fnameescape(sfile)
            return
        endif

        g:my_session = sfile
        # let `Track()` know that it must save & track the current session

        # Why not simply return after `Track()`, and move the `echo` statement in the latter?{{{
        #
        # `Track()`  is   frequently  called  by  the   autocmd  listening  to
        # `BufWinEnter`; we don't want the message to be echo'ed all the time.
        #
        # The message, and the renaming of the tmux pane, should only occur when
        # we begin the tracking of a new session.
        #}}}
        var error: string = Track()
        if error == ''
            echo 'Tracking session in ' .. fnamemodify(sfile, ':~:.')
            RenameTmuxWindow(sfile)
            return
        else
            Error(error)
            return
        endif

    finally
        redrawtabline
        [bang, sfile, last_used_session] = [false, '', '']
    endtry
enddef
var bang: bool
var sfile: string
var last_used_session: string

def Load(arg_session_file: string) #{{{2
    var session_file: string = arg_session_file == ''
        ?     get(g:, 'MY_LAST_SESSION', '')
        : arg_session_file == '%%'
        ?     get(g:, 'MY_PENULTIMATE_SESSION', '')
        : arg_session_file =~ '/'
        ?     fnamemodify(arg_session_file, ':p')
        :     SESSION_DIR .. '/' .. arg_session_file .. '.vim'

    session_file = resolve(session_file)

    if session_file == ''
        Error('No session to load')
        return
    elseif !filereadable(session_file)
        fnamemodify(session_file, ':t')
            ->printf("%s doesn't exist, or it's not readable")
            ->Error()
        return
    elseif exists('g:my_session') && session_file == g:my_session
        fnamemodify(session_file, ':t')
            ->printf('%s is already the current session')
            ->Error()
        return
    else
        var loaded_elsewhere: bool
        var file: string
        [loaded_elsewhere, file] = SessionLoadedInOtherInstance(session_file)
        if loaded_elsewhere
            printf('%s is already loaded in another Vim instance', file)
                ->Error()
            return
        endif
    endif

    PrepareRestoration(session_file)
    var options_save: dict<any> = SaveOptions()

    # Before restoring a session, we need to set the previous one (for `:SLoad %%`).
    # The previous one is:
    #    - the current tracked session, if there's one
    #    - or the last tracked session, "
    if exists('g:my_session')
        g:MY_PENULTIMATE_SESSION = g:my_session
    endif

    TweakSessionFile(session_file)
    # `silent!` to suppress a possible error when the session contains one of our folded notes.{{{
    #
    # It seems some  commands, like `zo`, fail to manipulate  a fold, because it
    # doesn't exist.  Maybe the buffer is not folded yet.
    #}}}
    execute 'silent! source ' .. fnameescape(session_file)
    # During the sourcing, other issues may occur. {{{
    #
    # Every custom function that we invoke in any autocmd (vimrc, other plugin)
    # may interfere with the restoration process.
    #
    # To prevent any issue, we could  restore the session while all autocmds are
    # disabled,  *then*  emit  `BufReadPost`  in all  buffers,  to  execute  the
    # autocmds associated to filetype detection:
    #
    #     noautocmd source ~/.vim/session/default.vim
    #     doautoall <nomodeline> filetypedetect BufReadPost
    #                            │
    #                            └ $VIMRUNTIME/filetype.vim
    #
    # But, this would cause other issues:
    #
    #    - the filetype plugins would be loaded too late for markdown buffers
    #      → 'foldmethod', 'foldexpr', 'foldtext' would be set too late
    #      → in the session file, commands handling folds (e.g. `zo`) would
    #        raise `E490: No fold found`
    #
    #   - `doautoall <nomodeline> filetypedetect  BufReadPost` would only affect
    #   the file in which the autocmd calling the current function is installed
    #      → no syntax highlighting everywhere else
    #      → we would have to delay the command with a timer or maybe
    #        a one-shot autocmd
    #
    # Solution:
    # In an autocmd which may interfere with the restoration process, test
    # whether `g:SessionLoad` exists.  This variable only exists while a session
    # is being restored:
    #
    #     if exists('g:SessionLoad')
    #         return
    #     endif
    #}}}

    if exists('g:my_session')
        g:MY_LAST_SESSION = g:my_session
    endif

    RestoreOptions(options_save)
    RestoreHelpOptions()
    RenameTmuxWindow(session_file)
    WinExecuteEverywhere('normal! zv')

    # use the global arglist in all windows
    # Why is it needed?{{{
    #
    # Before saving a session, we remove the  global arglist, as well as all the
    # local arglists.
    # I think that because of this, the session file executes these commands:
    #
    #     arglocal
    #     silent! argdel *
    #
    # ... for every window.
    # The `:arglocal` causes all windows to use the local arglist by default.
    #
    # I don't want that.
    # By default, Vim uses the global arglist, which should be the rule.
    # Using a local arglist should be the exception.
    #}}}
    WinExecuteEverywhere('argglobal')

    # reset height of window{{{
    #
    # Usually, this is not necessary.
    # But it's useful if the last time the session was saved you were focusing a
    # scratch buffer; such a buffer is  not restored, which causes the height of
    # the windows in the current tab page to be wrong.
    #}}}
    doautocmd <nomodeline> WinEnter

    # FIXME:
    # When we change the local directory of a window A, the next time
    # Vim creates a session file, it adds the command `:lcd some_dir`.
    # Because of this, the next time we load this session, all the windows
    # which are created after the window A inherit the same local directory.
    # They shouldn't.  We have excluded `'curdir'` from `'sessionoptions'`.
    #
    # Open an issue on Vim's repo.
    # In the meantime,  we invoke a function  to be sure that  the local working
    # directory of all windows is `~/.vim`.
    #
    #     var orig: number = win_getid()
    #     tabdo windo cd ~/.vim
    #     win_gotoid(orig)
    #
    # Update:
    # I've commented the code because it interferes with `vim-cwd`.
    #
    # ---
    #
    # I'm not sure the above is true.
    # When does Vim write `:lcd` in a session file?
    # It seems to do it even when I don't run `:lcd` manually...
enddef

def LoadSessionOnVimenter() #{{{2
    # Don't source the last session when we run `$ vim`; only when we run `$ nv`.
    # What's this `VIMSERVER` variable?{{{
    #
    # We set it only when we run `$ nv`.
    # Check out our zshrc:
    #
    #     VIMSERVER=yes vim -w /tmp/.vimkeys --servername "$server" "$@"
    #     ^-----------^
    #}}}
    # Do *not* inspect `v:servername` instead.{{{
    #
    # For example, you might be tempted to write this (and get rid of `$VIMSERVER`):
    #
    #     if v:servername != 'VIM'
    #         return
    #     endif
    #
    # That wouldn't work if Vim was not able to connect to the X server.
    # Because in  that case, `v:servername`  is empty, *even* if  you've started
    # Vim with the `--servername` argument.
    #
    # That can happen  if `&term` matches the pattern supplied  to the `exclude`
    # item in the `'clipboard'` option.  For  example, you might use the pattern
    # `.*`  to always  disallow a  connection to  the X  server, and  make Vim's
    # startup time a little faster:
    #
    #     &clipboard = 'autoselect,exclude:.*'
    #                                      ^^
    #}}}
    if $VIMSERVER == ''
        return
    endif

    var file: string = $HOME .. '/.vim/session/last'
    if filereadable(file)
        g:MY_LAST_SESSION = readfile(file)->get(0, '')
    endif

    # Why `/default.vim` in the pattern?{{{
    #
    # I don't like sourcing the  default session automatically; when it happens,
    # it's never  what I wanted,  and it's very  confusing, because I  lose time
    # wondering where the loaded files come from.
    #}}}
    # Why `^$` in the pattern?{{{
    #
    # If there's no last session, don't try to restore anything.
    #}}}
    if get(g:, 'MY_LAST_SESSION', '') =~ '/default.vim$\|^$'
        return
    endif

    if SafeToLoadSession()
        execute 'SLoad ' .. g:MY_LAST_SESSION
    endif
enddef

def PrepareRestoration(file: string) #{{{2
    # Update current session file, before loading another one.
    execute Track()

    # Let's make sure there's only 1 tabpage and 1 window.{{{
    #
    # If the current session contains several tabpages, they won't be closed.
    # For some  reason, `:mksession` writes  the command `:only` in  the session
    # file,  but not  `:tabonly`.   So,  we make  sure  every tabpage/window  is
    # closed, before restoring a session.
    #}}}
    # `:tabonly` displays a message if there's only 1 tab; `:silent` suppresses it.
    silent tabonly
    silent only
enddef

def Rename(new_name: string) #{{{2
    var src: string = g:my_session
    var dst: string = expand(SESSION_DIR .. '/' .. new_name .. '.vim')

    if rename(src, dst) != 0
        Error('Failed to rename ' .. src .. ' to ' .. dst)
        return
    else
        g:my_session = dst
        RenameTmuxWindow(dst)
    endif
enddef

def RenameTmuxWindow(file: string) #{{{2
    if !exists('$TMUX')
        return
    endif

    #                                              ┌ remove head (/path/to/)
    #                                              │ ┌ remove extension (.vim)
    #                                              │ │
    var window_title: string = fnamemodify(file, ':t:r')
    silent system('tmux rename-window -t ' .. $TMUX_PANE .. ' ' .. shellescape(window_title))

    augroup MyTmuxWindowTitle | autocmd!
        # We've just renamed the tmux window, so tmux automatically disabled the
        # 'automatic-rename' option.  We'll re-enable it when we quit Vim.
        autocmd VimLeavePre * silent system('tmux set-option -w -t ' .. $TMUX_PANE .. ' automatic-rename on')
    augroup END
enddef

def RestoreHelpOptions() #{{{2
    # Rationale:{{{
    #
    # Open a help file for a third-party plugin, then restart Vim (`SPC R`): the
    # file type is not set in the help file anymore.
    #
    # MWE:
    #
    #     $ vim +'help autocmd | tabnext | help fugitive | mksession! /tmp/.s.vim | quitall!' -p ~/.shrc ~/.bashrc
    #     $ vim -S /tmp/.s.vim
    #
    # The issue can be fixed by adding `options` in `'sessionoptions'`:
    #
    #     $ vim +'help autocmd | tabnext | help fugitive | set sessionoptions+=options | mksession! /tmp/.s.vim | quitall!' -p ~/.shrc ~/.bashrc
    #                                                      ^-------------------------^
    #
    # But I don't want to include this  item; when loading a session, I want all
    # options to be reset with sane values.
    #}}}
    var runtime_dirs: list<string> = split(&runtimepath, ',')
    remove(runtime_dirs, index(runtime_dirs, $VIMRUNTIME))

    var wininfos: list<dict<any>> = getwininfo()
        ->filter((_, v: dict<any>): bool =>
                   bufname(v.bufnr)->fnamemodify(':p') =~ '\C/doc/.*\.txt$'
                && index(runtime_dirs, bufname(v.bufnr)->fnamemodify(':p:h:h')) >= 0)

    for d: dict<any> in wininfos
        win_execute(d.winid, 'noswapfile set filetype=help')
    endfor

    # to be totally reliable, this block must come after the previous one
    # Rationale:{{{
    #
    # Without, a few options are not properly restored in a help buffer:
    #
    #    - `'buflisted'`
    #    - `'buftype'`
    #    - `'foldenable'`
    #    - `'iskeyword'`
    #    - `'modifiable'`
    #
    # In particular,  if `'iskeyword'` is  not correct, you  may not be  able to
    # jump to a tag (or preview it).
    #
    # MWE:
    #
    #     :help windows.txt
    #     /usr_07.txt
    #     SPC R
    #     :wincmd }
    #     E426: tag not found: usr_07˜
    #
    # And if `'bt'` is not correct, there may still be some problematic tags:
    #
    #     :help :bufdo /'eventignore'
    #     SPC R
    #     :wincmd }
    #     E426: tag not found: eventignore˜
    #
    # ---
    #
    # I found those options by comparing  the output of `:setlocal` in a working
    # help buffer, and in a broken one.
    #
    # ---
    #
    # Alternatively,  you could  also  close  the help  window,  and re-run  the
    # relevant `:help topic` command.
    #
    # Including the `localoptions` item in `'sessionoptions'` would also fix the
    # issue, but I  don't want to do  it, because when loading a  session I want
    # all options to be reset with sane values.
    #}}}
    var winids: list<number> = getwininfo()
        ->mapnew((_, v: dict<any>) => v.winid)
        ->filter((_, v: number): bool => getwinvar(v, '&filetype') == 'help')
    for winid: number in winids
        win_execute(winid, 'noautocmd RestoreThese()')
    endfor
enddef

def RestoreThese()
    &l:iskeyword = '!-~,^*,^|,^",192-255,-'
    # This is necessary to avoid that our statusline displays a spurious `[isk]` flag.{{{
    #
    # I tried to fix the issue in `vim-statusline` itself, but failed.
    # Too many corner cases, I guess.
    # So, now, we try to fix it here, which seems more reliable.
    #}}}
    b:orig_iskeyword = &l:iskeyword

    &l:buftype = 'help'
    &l:buflisted = false
    &l:foldenable = false
    &l:modifiable = false
enddef

def RestoreOptions(dict: dict<any>) #{{{2
    for [op: string, val: any] in items(dict)
        var newval: any
        if typename(val) == 'string'
            newval = string(val)
        else
            newval = val
        endif
        execute '&' .. op .. ' = ' .. newval
    endfor
enddef

def SafeToLoadSession(): bool #{{{2
    return !argc()
        && !read_stdin
        && &errorfile == 'errors.err'
        && get(g:, 'MY_LAST_SESSION', SESSION_DIR .. '/default.vim')
            ->filereadable()
        && !get(g:, 'MY_LAST_SESSION', SESSION_DIR .. '/default.vim')
            ->SessionLoadedInOtherInstance()[0]

    # It's safe to automatically load a session during Vim's startup iff:
    #
    #     Vim is started with no files to edit.
    #     If there are files to edit we don't want their buffers to be
    #     immediately lost by a restored session.
    #
    #     Vim isn't used in a pipeline.
    #
    #     Vim wasn't started with the `-q` option.
    #
    #     There's a readable session file to load.
    #
    #     No file in the session is already loaded in other instance.
    #     Otherwise, loading it in a 2nd instance would raise the error E325.
enddef

def SaveOptions(): dict<any> #{{{2
    # Save values of options which will be changed by the session file (to restore them later):{{{
    #
    #    - `'shortmess'`
    #    - `'splitbelow'`
    #    - `'splitright'`
    #    - `'showtabline'`
    #    - `'winheight'`
    #    - `'winminheight'`
    #    - `'winminwidth'`
    #    - `'winwidth'`
    #}}}
    # I don't include the `options` item in `'sessionoptions'`.  So, why do I need to save/restore these options?{{{
    #
    # Because Vim  *needs* to  temporarily change the  values of  these specific
    # options while restoring a session.
    # At  the end  of the  process, Vim  wants to  set those  options to  values
    # expected by the user.   The only values it knows the  user may expect, are
    # the ones which were used at the time the session file was created.
    # Therefore at the end of a session file, Vim writes `set winheight={current value}`:
    #
    #     $ vim -Nu NONE +'set winheight=123' +'mksession /tmp/.s.vim' +'quitall!' && grep -n 'winheight' /tmp/.s.vim
    #     6:set winheight=123˜
    #     23:set winheight=1˜
    #     153:set winheight=123 winwidth=20 shortmess=filnxtToOS˜
    #
    # But  this implies  that when  you load  a session,  these options  may not
    # be  preserved;  in  particular,  when  you restart  Vim,  and  the  latter
    # automatically  sources  the  last  session,   in  effect,  Vim  will  have
    # remembered the values of these options from the last session.
    # That's  not what  we want;  when  we restart,  we want  all custom  config
    # (options/mappings) to have been forgotten.
    #}}}
    # TODO: In the future you might be able to stop saving/restoring some of these options:{{{
    #
    #    - 'splitbelow'
    #    - 'splitright'
    #    - 'winminheight'
    #    - 'winminwidth'
    #
    # Vim should correctly restore them after this patch:
    # https://github.com/vim/vim/releases/tag/v8.2.2776
    #
    # However, we still save/restore them manually here, because we might source
    # session scripts which have been written by older Vim versions.
    #
    # ---
    #
    # And what about the other options, like `'shortmess'`?
    # Why didn't 8.2.2776 correctly restore them too?
    #}}}
    return {
        shortmess: &shortmess,
        splitbelow: &splitbelow,
        splitright: &splitright,
        showtabline: &showtabline,
        winheight: &winheight,
        winminheight: &winminheight,
        winminwidth: &winminwidth,
        winwidth: &winwidth,
    }
enddef

def SessionLoadedInOtherInstance(session_file: string): list<any> #{{{2
    var buffers: list<string> = readfile(session_file)
        ->filter((_, v: string): bool => v =~ '^badd ')

    if buffers == []
        return [0, '']
    endif

    buffers
        ->map((_, v: string) =>
                matchstr(v, '^badd +\d\+ \zs.*')->fnamemodify(':p'))

    var swapfiles: list<string> = buffers
        ->copy()
        ->map((_, v: string) =>
                    expand('~/.vim/tmp/swap/')
                 .. v->substitute('/', '%', 'g')
                 .. '.swp'
        )->map((_, v: string) => glob(v, true))
        #                                │
        #                                └ ignore 'wildignore'
        ->filter((_, v: string): bool => v != '')

    var a_file_is_currently_loaded: bool = swapfiles != []
    var it_is_not_in_this_session: bool = buffers
        ->mapnew((_, v: string): bool => buflisted(v))
        ->index(true) == -1
    var file: string = get(swapfiles, 0, '')
    file = fnamemodify(file, ':t:r')
            ->substitute('%', '/', 'g')
    return [a_file_is_currently_loaded && it_is_not_in_this_session, file]
enddef

def SessionDelete() #{{{2
    delete(last_used_session)

    # disable tracking of the session
    unlet! g:my_session

    #              reduce path relative to current working directory ┐
    #                                             don't expand `~` ┐ │
    #                                                              │ │
    echo 'Deleted session in ' .. fnamemodify(last_used_session, ':~:.')

    # Why do we empty `v:this_session`?
    #
    # If we don't, next time we try to save a session (:STrack),
    # the path in `v:this_session` will be used instead of:
    #
    #     ~/.vim/session/default.vim
    v:this_session = ''
enddef

def SessionPause() #{{{2
    echo 'Pausing session in ' .. fnamemodify(last_used_session, ':~:.')
    g:MY_LAST_SESSION = g:my_session
    unlet! g:my_session
    # don't empty `v:this_session`: we need it if we resume later
enddef

def ShouldDeleteSession(): bool #{{{2
    # `:STrack! ∅`
    return bang && sfile == ''
        # a session file was used and its file is readable
        && filereadable(last_used_session)
enddef

def ShouldPauseSession(): bool #{{{2
    # no bang
    return !bang
        # `:STrack ∅`
        && sfile == ''
        # the current session is being tracked
        && exists('g:my_session')
enddef

def session#status(): string #{{{2
    # From the perspective of sessions, the environment can be in 3 states:
    #
    #    - no session has been loaded / saved
    #
    #    - a session has been loaded / saved, but is NOT tracked by our plugin
    #
    #    - a session has been loaded / saved, and IS being tracked by our plugin

    # We create the variable `state` whose value, 0, 1 or 2, stands for
    # the state of the environment.
    #
    #                    ┌ a session has been loaded/saved
    #                    │                                ┌ it's tracked by our plugin
    #                    │                                │
    var state: number = (v:this_session != '' ? 1 : 0) + (exists('g:my_session') ? 1 : 0)
    #                    │
    #                    └ stores the path to the last file which has been used
    #                      to load/save a session;
    #                      if no session has been saved/loaded, it's empty
    #
    # We can use this sum to express the state because there's no ambiguity.
    # Only 1 state can produce 0.
    # Only 1 state can produce 1.
    # Only 1 state can produce 2.
    #
    # If 2 states could produce 1, we could NOT use this sum.
    # More generally, we need a bijective, or at least injective, math function,
    # so that no matter the value we get, we can retrieve the exact state
    # which produced it.

    # return an item to display in the statusline
    #
    #       ┌ no session has been loaded/saved
    #       │     ┌ a session has been loaded/saved, but isn't tracked
    #       │     │      ┌ a session is being tracked
    #       │     │      │
    return ['', '[S]', '[∞]'][state]
enddef

def SuggestSessions(arglead: string, _, _): string #{{{2
    return SESSION_DIR
        ->readdir((n: string): bool => n =~ '\.vim$')
        ->join("\n")
        # remove files extension
        ->substitute('[^\n]*\zs\.vim', '', 'g')
    #                 ├───┘
    #                 └ in a regex used to describe text in a BUFFER
    #                   `.` stands for any character EXCEPT an end-of-line
    #
    #                   in a regex used to describe text in a STRING
    #                   `.` stands for any character INCLUDING an end-of-line
enddef

def Track(on_vimleavepre = false): string #{{{2
    # This function saves the current session, iff `g:my_session` exists.
    # In the session file, it adds the line:
    #
    #     let g:my_session = v:this_session
    #
    # ... so that  the next time we  load the session, the plugin  knows that it
    # must track it automatically.

    if exists('g:SessionLoad')
        # `g:SessionLoad` exists temporarily while a session is loading.{{{
        #
        # See: `:help SessionLoad-variable`
        #
        # Suppose we source a session file:
        #
        #     :source file
        #
        # During the  restoration process, `BufWinEnter` would  be fired several
        # times.   Every time,  the current  function  would try  to update  the
        # session file.  This would overwrite the file, while it's being used to
        # restore the session.  We don't want that.
        #
        # The session file will be updated next time (`BufWinEnter`, `TabClosed`,
        # `VimLeavePre`).
        #}}}
        return ''
    endif

    # update the session  iff / as soon as  this variable exists
    if exists('g:my_session')
        try
            if on_vimleavepre
                # Why do it?{{{
                #
                # Because, Vim takes  a long time to re-populate  a long arglist
                # when sourcing a session.
                #
                # This is due to the fact that `:mksession` doesn't write in the
                # session file the same command we used to populate the arglist.
                # Instead, it executes `:argadd` for EVERY file in the arglist.
                #
                # MWE:
                #     :args $VIMRUNTIME/**/*.vim
                #     SPC R
                #}}}
                # Why not simply `:% argdelete`?{{{
                #
                # It would fail  to remove a long local arglist  associated to a
                # window other than the currently focused one.
                #
                # MWE:
                #     :args $VIMRUNTIME/**/*.vim
                #     # focus another window
                #     SPC R
                #}}}
                # remove the global arglist
                argglobal | :% argdelete
                # remove all the local arglists
                WinExecuteEverywhere('arglocal | :% argdelete')
            endif

            #                 ┌ overwrite any existing file
            #                 │
            execute 'mksession! ' .. fnameescape(g:my_session)

            # Let Vim know that this session is the last used.
            # Useful when we do this:
            #
            #     :STrack        stop the tracking of the current session
            #     :STrack new    create and track a new one
            #     :quit          quit Vim
            #     $ vim          restart Vim
            g:MY_LAST_SESSION = g:my_session

        catch /^Vim\%((\a\+)\)\=:E\%(788\|11\):/
            # About E788:{{{
            #
            # Since Vim  8.0.677, some  autocmds listening to  `BufWinEnter` may
            # not work all the time.  Sometimes they raise the error `E788`.
            # For us, it happens when we open the qf window (`:copen`).
            # Minimal vimrc to reproduce:
            #
            #     autocmd BufWinEnter * mksession! /tmp/session.vim
            #     copen
            #
            # Basically, `:mksession` (temporarily?)  changes the current buffer
            # when 'filetype' is set to 'qf', which is now forbidden.
            # For more info, search `E788` on Vim's bug tracker.
            #
            # Here, we simply ignore the error.
            # More generally, when we want to  do sth which is forbidden because
            # of a  lock, we  could use  `feedkeys()` and  a plug  mapping which
            # would execute arbitrary code:
            # https://github.com/vim/vim/issues/1839#issuecomment-315489118
            #}}}
            # About E11:{{{
            #
            # Since  Vim 8.1.2017,  running `:mksession`  from the  command-line
            # window raises `E11`.
            #
            #     Error detected while processing BufWinEnter Autocommands for "*":
            #     Vim(mksession):E11: Invalid in command-line window; <CR> executes, CTRL-C quits: mksession! /home/jean/.vim/session/C.vim
            #}}}
        catch
            # If sth goes  wrong now (e.g.: session file not  writable), it will
            # probably go wrong next time.
            # We don't want to go on trying to save a session.
            unlet! g:my_session
            # remove `[∞]` from the tab line
            redrawtabline
            return 'echoerr ' .. string(v:exception)
        endtry
    endif
    return ''
enddef

def TweakSessionFile(file: string) #{{{2
    #   ┌ lines of our session file
    #   │
    var body: list<string> = readfile(file)

    # add the Ex command:
    #
    #     let g:my_session = v:this_session
    #
    # ... just before the last 3 commands:
    #
    #     doautoall SessionLoadPost
    #     unlet SessionLoad
    #     vim: set ft=vim : (modeline)
    insert(body, 'let g:my_session = v:this_session', -3)
    # Why twice?{{{
    #
    # Once, I had an issue where this line was missing in a session file.
    # This  lead to  an issue  where, when  I restarted  Vim, the  wrong
    # session was systematically loaded.
    #}}}
    insert(body, 'let g:my_session = v:this_session', -3)
    writefile(body, file)
enddef

def VimQuitAndRestart() #{{{2
    if has('gui_running')
        echo 'not available in GUI'
        return
    endif
    # `:silent!` to suppress `:help E382` (might happen when we're in a terminal buffer)
    silent! update
    # Source:
    # https://www.reddit.com/r/vim/comments/5lj75f/how_to_reload_vim_completely_using_zsh_exit_to/

    # Send the signal `USR1` to the shell  parent of the current Vim process,
    # so that it restarts a new one when we'll get back at the prompt.
    # Do NOT use `:!`.{{{
    #
    # It would cause a hit-enter prompt when Vim restarts.
    #}}}
    var shell_parent_pid: string = '$(ps -p ' .. getpid() .. ' -o ppid=)'
    silent system('kill -USR1 ' .. shell_parent_pid)

    # Note that the shell doesn't seem to process the signal immediately.
    # It doesn't restart a new Vim process, until we've quit the current one.
    # That's probably because  the shell stays in the background  as long as Vim
    # is running.
    quitall!
enddef

def WhereDoWeSave(): string #{{{2
    # `:STrack ∅`
    if sfile == ''
        if last_used_session == ''
            if !isdirectory(SESSION_DIR)
                mkdir(SESSION_DIR, 'p', 0o700)
            endif
            return SESSION_DIR .. '/default.vim'
        else
            return last_used_session
        endif

    # :STrack dir/
    elseif isdirectory(sfile)
        echohl ErrorMsg
        echo 'provide the name of a session file; not a directory'
        echohl NONE
        # Why don't you return anything?{{{
        #
        # Like:
        #
        #     return fnamemodify(sfile, ':p') .. 'default.vim'
        #
        # Because:
        #     :edit ~/wiki/par/par.md
        #     :SClose
        #     :STrack par
        #     the session is saved in ~/wiki/par/default.vim˜
        #     it should be in ~/.vim/session/par.vim˜
        #
        # I think it's an argument in favor of not supporting the feature `:STrack dir/`.
        #}}}
        return ''

    # :STrack file
    else
        return sfile =~ '/'
            ?     fnamemodify(sfile, ':p')
            :     SESSION_DIR .. '/' .. sfile .. '.vim'
    endif
enddef

def WinExecuteEverywhere(cmd: string) #{{{2
    try
        for d: dict<any> in getwininfo()
            win_execute(d.winid, 'noautocmd ' .. cmd)
        endfor
    # ERROR: Vim(argglobal):E565: Not allowed to change text or change window:{{{
    #
    # Last time it happened, it was during a crash.
    # Maybe catching the error will prevent similar crashes in the future...
    #}}}
    catch /^Vim\%((\a\+)\)\=:E565:/
        Error(v:exception)
    endtry
enddef

def Error(msg: string) #{{{2
    echohl ErrorMsg
    echomsg msg
    echohl NONE
enddef
#}}}1
# Mapping {{{1

nnoremap <unique> <Space>R <Cmd>call <SID>VimQuitAndRestart()<CR>

# Options {{{1
# sessionoptions {{{2

# The default value contains many undesirable items:{{{
#
#    - blank: we don't want to save empty windows when `:mksession` is executed
#
#    - buffers: we don't want to restore hidden and unloaded buffers
#
#    - curdir: we don't want to save the current directory when we start Vim,
#      we want the current directory to be the same as the one in the shell,
#      otherwise it can lead to confusing situations when we use `**`
#
#    - folds: we don't want local fold options to be saved
#      (same reason as for 'options' item)
#      see also: https://github.com/Konfekt/FastFold/issues/57
#
#    - options: we don't want to save options and mappings,
#      because if we make some experiments and change some options/mappings
#      during a session, we don't want those to be restored;
#      only those written in files should be (vimrc, plugins, ...)
#
#      folding options are not affected by this item (for those you need the 'folds' item)
#}}}
&sessionoptions = 'help,tabpages,winsize'
#}}}1
# Variables {{{1

const SESSION_DIR: string = $HOME .. '/.vim/session'

# Documentation {{{1
#
# `:STrack` can receive 5 kind of names as arguments:
#
#    - nothing
#    - a new file (doesn't exist yet)
#    - an empty file (exists, but doesn't contain anything)
#    - a regular file
#    - a session file
#
# Also, `:STrack` can be suffixed with a bang.
# So, we can execute 10 kinds of command in total.
# They almost all track the session.
# This is a *design decision* (the command could behave differently).
# We design the command so that, by default, it tracks the current session,
# no matter the argument / presence of a bang.
# After all, this is its main purpose.
#
# However, we want to add 2 features: pause and deletion.
# And we don't want to overwrite an important file by accident.
# These are 3 special cases:
#
#    ┌──────────────────────┬─────────────────────────────────────────┐
#    │ :STrack              │ if the current session is being tracked │
#    │                      │ the tracking is paused                  │
#    ├──────────────────────┼─────────────────────────────────────────┤
#    │ :STrack!             │ if the current session is being tracked │
#    │                      │ the tracking is paused                  │
#    │                      │ AND the session file is deleted         │
#    ├──────────────────────┼─────────────────────────────────────────┤
#    │ :STrack regular_file │ fails (E189)                            │
#    └──────────────────────┴─────────────────────────────────────────┘
#
# ---
#
#    - `:STrack file`
#    - `:STrack /path/to/file`
#    - `:STrack relative/path/to/file`
#
# Invoke `:mksession` on:
#
#    - ~/.vim/session/file
#    - /path/to/file
#    - cwd/path/to/file
#
# ... iff `file` doesn't exist.
#
# Update the file whenever `BufWinEnter`, `TabClosed` or `VimLeavePre` is fired.
#
# ---
#
# `:STrack!` invokes `:mksession!`, which tries to overwrite the file no matter what.
#
# ---
#
#     :STrack
#
# If the tracking of a session is running:  pause it
# If the tracking of a session is paused:  resume it
#
# If  no  session is  being  tracked,  start  tracking  the current  session  in
# `~/.vim/session/default.vim`.
#
# TODO: It should be in:
#
#     `:pwd`/session.vim
#
# ---
#
#     :STrack!
#
# If no session is being tracked, begin the tracking.
# If the tracking of a session is running: pause it and remove the session file.
#
#
# Loading a session created with `:STrack` automatically resumes updates to that
# file.
#
# ---
#
#     :SDelete!
#     :SRename foo
#
# Delete current session.
# Rename current session into `~/.vim/session/foo`.
#
# ---
#
#     :SLoad
#
# Load last used session.  Useful after `:SClose`.
#
# ---
#
#     :SLoad %%
#     :SDelete! %%
#
# Load / Delete the previous session.
#
# ---
#
#     :SLoad foo
#     :SDelete! foo
#
# Load / Delete session `foo` stored in `~/.vim/session/foo.vim`.
#
# ---
#
#     :SLoad /path/to/session.vim
#
# Load session stored in `/path/to/session.vim`.
#
# TODO:
# Is it really useful?
# If not, remove this feature.
# I've added it because `:SLoad dir/` create  a session file in `dir/`, which is
# not `~/.vim/session`.
#
# If you keep it,  `:SLoad` should be able to suggest the names  of the files in
# `dir/`.
# It would  need to  deduce from  what you've typed,  whether it's  a part  of a
# session name, or of a path (relative/absolute) to a session file.
#
# ---
#
#     :SClose
#
# Close the session:  stop the tracking of the session, and close all windows
#
