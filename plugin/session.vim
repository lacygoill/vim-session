if exists('g:loaded_session')
    finish
endif
let g:loaded_session = 1

" Autocmds {{{1

augroup my_session
    au!
    au StdInReadPost * let s:read_stdin = 1

    "             ┌─ necessary to source ftplugins (trigger autocmds listening to BufReadPost?)
    "             │
    au VimEnter * nested if s:safe_to_load_session()
                      \|     exe 'SLoad '.get(g:, 'MY_LAST_SESSION', 'default')
                      \| endif

    " Purpose of the next 3 autocmds: {{{
    "
    "     1. automatically save the current session, as soon as `g:my_session`
    "        pops into existence
    "
    "     2. update the session file frequently, and as long as `g:my_session` exists
    "        IOW, track the session
"}}}
    "                ┌─ if sth goes wrong, the function returns the string:
    "                │       'echoerr '.string(v:exception)
    "                │
    "                │  we need to execute this string
    "                │
    au BufWinEnter * exe s:track(0)
    "  │
    "  └─ We don't want the session to be saved only when we quit Vim,
    "     because Vim could exit abnormally.
    "
    "     Contrary to `BufEnter`, `BufWinEnter` is NOT fired for `:split`
    "     (without arguments), nor for `:split file`, `file` being already
    "     displayed in a window.
    "
    "     But most of the time, Vim won't quit abnormally, and the last saved
    "     state of our session will be performed when VimLeavePre is fired.
    "     So, `VimLeavePre` will have the final say most of the time.

    au TabClosed * call timer_start(0, {-> execute('exe '.s:snr().'track(0)')})
    " We also save whenever we close a tabpage, because we don't want
    " a closed tabpage to be restored while we switch back and forth between
    " 2 sessions with `:SLoad`.
    " But, we can't save the session immediately, because for some reason, Vim
    " would only save the last tabpage (or the current one?). So, we delay the
    " saving.

    au VimLeavePre * exe s:track(1)
augroup END

" Commands {{{1

" Why `exe s:handle_session()` {{{
" and why `exe s:track()`?
"
" If an error occurs in a function, we'll get an error such as:
"
"         Error detected while processing function <SNR>42_track:
"         line   19:
"         Vim:E492: Not an editor command:             abcd
"
" We want our `:STrack` command, and our autocmd, to produce a message similar
" to a regular Ex command. We don't want the detail of the implementation to leak.
"
" By using `exe function()`, we can get an error message such as:
"
"         Error detected while processing BufWinEnter Auto commands for "*":
"         Vim:E492: Not an editor command:             abcd
"
" How does it work?
" When an error may occur, we capture it and convert it into a string:
"
"     try
"         …
"     catch
"         return 'echoerr '.string(v:exception)
"     endtry
"
" We execute this string in the context of `:STrack`, or of the autocmd.
" Basically, the try conditional + `exe function()` is a mechanism which
" allows us to choose the context in which an error may occur.
" Note, however, that in this case, it prevents our `:WTF` command from capturing
" the error, because it will happen outside of a function.
" "}}}

" We use `:echoerr` for `:SDelete`, `:SRename`, `:SClose`, because we want the
" command to disappear if no error occurs during its execution.
" For `:SLoad` and `:STrack`, we use `:exe` because there will always be
" a message to display; even when everything works fine.
com! -bar                -complete=customlist,s:suggest_sessions SClose   exe s:close()
com! -bar -bang -nargs=? -complete=customlist,s:suggest_sessions SDelete  exe s:delete(<bang>0, <q-args>)
com! -bar       -nargs=1 -complete=customlist,s:suggest_sessions SRename  exe s:rename(<q-args>)

com! -bar       -nargs=? -complete=customlist,s:suggest_sessions SLoad    exe s:load(<q-args>)
com! -bar -bang -nargs=? -complete=file                          STrack   exe s:handle_session(<bang>0, <q-args>)

" Functions "{{{1
fu! s:close() abort "{{{2
    if !exists('g:my_session')
        return ''
    endif

    sil STrack
    sil! tabonly | sil! only | enew
    call s:rename_tmux_window('vim')
    return ''
endfu

fu! s:delete(bang, session) abort "{{{2
    if !a:bang
        return 'echoerr "Add a bang"'
    endif

    if a:session ==# '#'
        if exists('g:MY_PENULTIMATE_SESSION')
            let session_file = g:MY_PENULTIMATE_SESSION
        else
            return 'echoerr "No alternate session to delete"'
        endif
    else
        let session_file = empty(a:session)
        \?                     get(g:, 'my_session', 'MY_LAST_SESSION')
        \:                     fnamemodify(s:session_dir.'/'.a:session.'.vim', ':p')
    endif

    if exists('g:my_session') && session_file ==# g:my_session
        if exists('g:MY_PENULTIMATE_SESSION')
            " We have to load the alternate session BEFORE deleting the session
            " file, because `:SLoad#` will take a last snapshot of the current
            " session, which would restore the deleted file.
            sil! SLoad#
            " The current session has just become the alternate one.
            " Since we're going to delete its file, make the plugin forget about it.
            unlet! g:MY_PENULTIMATE_SESSION
        else
            SClose
        endif
    endif

    " Delete the session file, and if sth goes wrong report what happened.
    if delete(session_file)
        " Do NOT use `printf()`:
        "         return printf('echoerr "Failed to delete %s"', session_file)
        "
        " It would fail when the name of the session file contains a double quote.
        return 'echoerr '.string('Failed to delete '.session_file)
    endif
    return 'echo '.string(session_file.' has been deleted')
endfu

fu! s:handle_session(bang, file) abort "{{{2
    " We move `a:bang`, `a:file` , and put `s:last_used_session` into the
    " script-local scope, to NOT have to pass them as arguments to various
    " functions:
    "
    "         s:should_delete_session()
    "         s:session_delete()
    "         s:should_pause_session()
    "         s:session_pause()
    "         s:where_do_we_save()

    let s:bang = a:bang
    let s:file = a:file
    " This variable is used by:
    "
    "         • s:session_pause()
    "         • s:session_delete()
    "         • s:where_do_we_save()
    "
    " It's useful to be able to delete a session which isn't currently
    " tracked, and to track the session using the session file of the last
    " session used.
    let s:last_used_session = get(g:, 'my_session', v:this_session)

    try
        " `:STrack` should behave mostly like `:mksession` with the
        " additional benefit of updating the session file.
        "
        " However, we want 2 additional features:  pause and deletion.
        "
        "         :STrack     pause
        "         :STrack!    delete

        if s:should_pause_session()
            return s:session_pause()
        elseif s:should_delete_session()
            return s:session_delete()
        endif

        let s:file = s:where_do_we_save()
        if empty(s:file) | return '' | endif

        "  ┌─ we only care whether a file is readable if NO bang is given
        "  │
        "  │  Otherwise, we try to overwrite the file no matter what.
        "  │  `:mksession! file` tries to overwrite `file`.
        "  │  `:STrack!` should do the same.
        "  │
        if !s:bang && filereadable(s:file) | return 'mksession '.fnameescape(s:file) | endif
        "                                           └──────────────────────────────┤
        "                                                                          │
        " We don't want to raise an error from the current function (ugly stack trace).
        " The user only knows about `:mksession`, so the error must look like
        " it's coming from the latter.
        " We just return 'mksession file'. It will be executed outside this function,
        " fail, and produce the “easy-to-read“ error message:
        "
        "         E189: "file" exists (add ! to override)

        let g:my_session = s:file
        " let `track()` know that it must save & track the current session

        " Why not simply return `s:track()`, and move the `echo` statement in
        " the latter?
        " `s:track()` is frequently called by the autocmd listening to
        " BufWinEnter. We don't want the message to be echo'ed all the time.
        " The message, and the renaming of the tmux pane, should only occur
        " when we begin the tracking of a new session.
        let error = s:track(0)
        if empty(error)
            echo 'Tracking session in '.fnamemodify(s:file, ':~:.')
            call s:rename_tmux_window(s:file)
            return ''
        else
            return error
        endif

    finally
        redrawstatus!
        unlet! s:bang s:file s:last_used_session
    endtry
endfu

fu! s:load(file) abort "{{{2
    let file = empty(a:file)
    \?             get(g:, 'MY_LAST_SESSION', '')
    \:         a:file ==# '#'
    \?             get(g:, 'MY_PENULTIMATE_SESSION', '')
    \:         a:file =~# '/'
    \?             fnamemodify(a:file, ':p')
    \:             s:session_dir.'/'.a:file.'.vim'

    let file = resolve(file)

    if empty(file)
        return 'echoerr "No session to load"'
    elseif !filereadable(file)
        " Do NOT use `printf()` like this
        "         return printf('echoerr "%s doesn''t exist, or it''s not readable"', fnamemodify(file, ':t'))
        return 'echoerr '.string(printf("%s doesn't exist, or it's not readable", fnamemodify(file, ':t')))
    elseif s:session_loaded_in_other_instance(file)[0]
        let file = substitute(fnamemodify(s:session_loaded_in_other_instance(file)[1], ':t:r'), '%', '/', 'g')
        return 'echoerr '.string(printf('%s is already loaded in another Vim instance', file))
    elseif exists('g:my_session') && file ==# g:my_session
        return 'echoerr '.string(printf('%s is already the current session', fnamemodify(file, ':t')))
    endif

    call s:prepare_restoration(file)

    " Even though we don't include 'options' inside 'ssop', a session file
    " manipulates the value of 'shm'. We save and restore this option
    " manually, to be sure it won't be changed.
    let shm_save = &shm

    " Before restoring a session, we need to set the previous one (for `:SLoad#`).
    " The previous one is:
    "         - the current tracked session, if there's one
    "         - or the last tracked session, "
    if exists('g:my_session')
        let g:MY_PENULTIMATE_SESSION = g:my_session
    endif

    "  ┌─ Sometimes, when the session contains one of our folded notes,
    "  │  an error is raised. It seems some commands, like `zo`, fail to
    "  │  manipulate a fold, because it doesn't exist. Maybe the buffer is not
    "  │  folded yet.
    "  │
    sil! exe 'so '.fnameescape(file)
    " During the sourcing, other issues may occur. {{{
    "
    " Every custom function that we invoke in any autocmd (vimrc, other plugin)
    " may interfere with the restoration process.
    " For an example, have a look at `s:dnb_clean()` in vimrc.
    "
    " To prevent any issue, we could restore the session while all autocmds are
    " disabled, THEN emit `BufReadPost` in all buffers, to execute the autocmds
    " associated to filetype detection:
    "
    "         noautocmd so ~/.vim/session/default.vim
    "         doautoall filetypedetect BufReadPost
    "                   │
    "                   └─ $VIMRUNTIME/filetype.vim
    "
    " But, this would cause other issues:
    "
    "       the filetype plugins would be loaded too late for markdown buffers
    "           → 'fdm', 'fde', 'fdt' would be set too late
    "           → in the session file, commands handling folds (e.g. `zo`) would
    "             raise `E490: No fold found`
    "
    "       `doautoall filetypedetect BufReadPost` would only affect the file in
    "       which the autocmd calling the current function is installed
    "           → no syntax highlighting everywhere else
    "           → we would have to delay the command with a timer or maybe
    "             a fire-once autocmd
    "
    " Solution:
    " In an autocmd which may interfere with the restoration process, test
    " whether `g:SessionLoad` exists. This variable only exists while a session
    " is being restored:
    "
    "         if exists('g:SessionLoad')
    "             return
    "         endif
"}}}

    let &shm = shm_save
    let g:MY_LAST_SESSION = g:my_session

    call s:restore_help_settings_when_needed()
    call s:restore_window_local_settings()
    call s:rename_tmux_window(file)
    return ''
endfu

fu! s:prepare_restoration(file) abort "{{{2
    " Update current session file, before loading another one.
    exe s:track(0)

    " If the current session contains several tabpages, they won't be closed.
    " For some reason, `:mksession` writes the command `:only` in the session
    " file, but not `:tabonly`. So, we make sure every tabpage/window is
    " closed, before restoring a session.
    sil! tabonly | sil! only
    "  │
    "  └─ if there's only 1 tab, `:tabonly` will display a message
endfu

fu! s:rename(new_name) abort "{{{2
    let src = g:my_session
    let dst = expand(s:session_dir.'/'.a:new_name.'.vim')

    if rename(src, dst)
        return 'echoerr '.string('Failed to rename '.src.' to '.dst)
    else
        let g:my_session = dst
        call s:rename_tmux_window(dst)
    endif
    return ''
endfu

fu! s:rename_tmux_window(file) abort "{{{2
    if !exists('$TMUX')
        return
    endif

    "                                               ┌─ remove head (/path/to/)
    "                                               │ ┌─ remove extension (.vim)
    "                                               │ │
    let window_title = string(fnamemodify(a:file, ':t:r'))
    call system('tmux rename-window -t '.$TMUX_PANE.' '.window_title)

    augroup my_tmux_window_title
        au!
        " We've just renamed the tmux window, so tmux automatically
        " disabled the 'automatic-rename' option. We'll re-enable it when
        " we quit Vim.
        au VimLeavePre * call system('tmux set-option -w -t '.$TMUX_PANE.' automatic-rename on')
    augroup END
endfu

fu! s:restore_help_settings() abort "{{{2
    " For some reason, Vim doesn't restore some settings in a help buffer,
    " including the syntax highlighting.

    setl ft=help nobuflisted noma ro
    so $VIMRUNTIME/syntax/help.vim

    augroup restore_help_settings
        au! * <buffer>
        au BufReadPost <buffer> setl ft=help nobuflisted noma ro
    augroup END

    " TODO:
    " Isn't there a simpler solution?
    " Vim doesn't rely on an autocmd to restore the settings of a help buffer.
    " Confirmed by typing:         au * <buffer=42>
    "
    " If we reload a help buffer, without installing an autocmd to restore the
    " filetype, the latter gets back to `text`.
    " If we re-open the file with the right `:h tag`, it opens a new window,
    " with the same `text` file. From there, if we reload the file, it gets
    " back to `help` in both windows. It happens with and without the 1st
    " command:
    "
    "         setl ft=help nobuflisted noma ro
    "
    " I've tried to hook into all the events fired by `:h`, but none worked.

    " We could also do that:
    "
    "         exe 'h '.matchstr(expand('%'), '.*/doc/\zs.*\.txt')
    "         exe "norm! \<c-o>"
    "         e
    "
    " But for some reason, `:e` doesn't do its part. It should immediately
    " re-apply syntax highlighting. It doesn't. We have to reload manually (:e).
endfu

fu! s:restore_help_settings_when_needed() abort "{{{2
    " `:bufdo` is executed in the context of the last window of the last tabpage.
    " It could replace its buffer with another buffer (the one with the biggest number).
    " We don't want that, so we save the current buffer number, to restore it later.
    let cur_bufnr = bufnr('%')

    sil! bufdo if expand('%') =~# '/doc/.*\.txt$'
            \|     call s:restore_help_settings()
            \| endif

    " I had an `E86` error once (buffer didn't exist anymore).
    if bufexists(cur_bufnr)
        exe 'b '.cur_bufnr
    endif
endfu

fu! s:restore_window_local_settings() abort "{{{2
    let cur_winid = win_getid()

    " We fire `BufWinEnter` in all windows to apply window-local options in
    " all opened windows. Also, it may be useful to position us at the end of
    " the changelist (through our autocmd `my_changelist` which listens to this
    " event).
    "
    " Why not simply:
    "       doautoall BufWinEnter
    " ?
    " Because `:doautoall` executes the autocmds in the context of the BUFFERS.
    " But their purpose is to set WINDOW-local options.
    " They need to be executed in the context of the windows, not the buffers.
    "
    " Watch:
    "         bufdo setl list          only affects current window
    "         windo setl list          only affects windows in current tabpage
    "         tabdo windo setl list    affects all windows

    tabdo windo sil! doautocmd <nomodeline> BufWinEnter
    " │   │        │
    " │   │        └─ an error shouldn't interrupt the process
    " │   └─ iterate over windows
    " └─ iterate over tabpages

    call win_gotoid(cur_winid)
endfu

fu! s:safe_to_load_session() abort "{{{2
    return !argc()
       \&& !get(s:, 'read_stdin', 0)
       \&& filereadable(get(g:, 'MY_LAST_SESSION', 'default'))
       \&& !s:session_loaded_in_other_instance(get(g:, 'MY_LAST_SESSION', 'default'))[0]

    " It's safe to automatically load a session during Vim's startup iff:
    "
    "     Vim is started with no files to edit.
    "     If there are files to edit we don't want their buffers to be
    "     immediately lost by a restored session.
    "
    "     Vim isn't used in a pipeline.
    "
    "     There's a readable session file to load.
    "
    "     No file in the session is already loaded in other instance.
    "     Otherwise, loading it in a 2nd instance would raise the error E325.
endfu

fu! s:session_loaded_in_other_instance(session_file) abort "{{{2
    let buffers = filter(readfile(a:session_file), 'v:val =~# "^badd"')

    if empty(buffers)
        return 0
    endif

    " Never assign to a variable, the output of a function which operates{{{
    " in-place on a list:  map()  filter()  reverse()  sort()  uniq()
    " Unless, the list is the output of another function (including `copy()`):
    "
    "         let list = map([1,2,3], 'v:val + 1')             ✘
    "
    "         call map([1,2,3], 'v:val + 1')                   ✔
    "         let list = map(copy([1,2,3]), 'v:val + 1')       ✔
    "         let list = map(tabpagebuflist(), 'v:val + 1')    ✔
    "
    " Why?
    " It gives you the wrong idea that the contents of the variable is a copy
    " of the original list/dictionary.
    " Ex:
    "
    "         let list1 = [1,2,3]
    "         let list2 = map(list1, 'v:val + 1')
    "
    " You may think that `list2` is a copy of `list1`, and that changing `list2`
    " shouldn't affect `list1`. Wrong. `list2`  is just another reference
    " pointing to `list1`. Proof:
    "
    "         call map(list2, 'v:val + 2')
    "         → increments all elements of `list2`, but also all elements of `list1`
    "
    " A less confusing way of writing this code would have been:
    "
    "         let list1 = [1,2,3,4,5]
    "         call map(list1, 'v:val + 1')
    "
    " Without assigning the output of `map()` to a variable, we don't get the
    " idea that we have a copy of `list1`. And if we need one, we'll immediately
    " think about `copy()`:
    "
    "         let list1 = [1,2,3,4,5]
    "         let list2 = map(copy(list1), 'v:val + 1')
"}}}
    call map(buffers, "matchstr(v:val, '^badd +\\d\\+ \\zs.*')")
    call map(buffers, "fnamemodify(v:val, ':p')")

    let swapfiles = map(copy(buffers), "expand('~/.vim/tmp/swap/').substitute(v:val, '/', '%', 'g').'.swp'")
    call filter(map(swapfiles, 'glob(v:val, 1)'), 'v:val != ""')
    "                                       │
    "                                       └─ ignore 'wildignore'

    let a_file_is_currently_loaded = !empty(swapfiles)
    let it_is_not_in_this_session = empty(filter(map(buffers, 'buflisted(v:val)'), 'v:val != 0'))
    return [ a_file_is_currently_loaded && it_is_not_in_this_session, get(swapfiles, 0, '') ]
endfu

fu! s:session_delete() abort "{{{2
    call delete(s:last_used_session)

    " disable tracking of the session
    unlet! g:my_session

    "             reduce path relative to current working directory ┐
    "                                            don't expand `~` ┐ │
    "                                                             │ │
    echo 'Deleted session in '.fnamemodify(s:last_used_session, ':~:.')

    " Why do we empty `v:this_session`?
    "
    " If we don't, next time we try to save a session (:STrack),
    " the path in `v:this_session` will be used instead of:
    "
    "         ~/.vim/session/default.vim
    let v:this_session = ''
    return ''
endfu

fu! s:session_pause() abort "{{{2
    echo 'Pausing session in '.fnamemodify(s:last_used_session, ':~:.')
    let g:MY_LAST_SESSION = g:my_session
    unlet g:my_session
    " don't empty `v:this_session`: we need it if we resume later
    return ''
endfu

fu! s:should_delete_session() abort "{{{2
    "                            ┌ :STrack! ∅
    "      ┌─────────────────────┤
    return s:bang && empty(s:file) && filereadable(s:last_used_session)
    "                                 │
    "                                 └─ a session file was used and its file is readable
endfu

fu! s:should_pause_session() abort "{{{2
    "      ┌─ no bang
    "      │          ┌─ :STrack ∅
    "      │          │                ┌─ the current session is being tracked
    "      │          │                │
    return !s:bang && empty(s:file) && exists('g:my_session')
endfu

fu! s:snr() "{{{2
    return matchstr(expand('<sfile>'), '<SNR>\d\+_')
endfu

fu! session#status() abort "{{{2

    " From the perspective of sessions, the environment can be in 3 states:
    "
    "         - no session has been loaded / saved
    "
    "         - a session has been loaded / saved, but is NOT tracked by our plugin
    "
    "         - a session has been loaded / saved, and IS being tracked by our plugin

    " We create the variable `state` whose value, 0, 1 or 2, stands for
    " the state of the environment.
    "
    "           ┌─ a session has been loaded/saved
    "           │                        ┌─ it's tracked by our plugin
    "           │                        │
    let state = !empty(v:this_session) + exists('g:my_session')
    "                  │
    "                  └─ stores the path to the last file which has been used
    "                     to load/save a session;
    "                     if no session has been saved/loaded, it's empty
    "
    " We can use this sum to express the state because there's no ambiguity.
    " Only 1 state can produce 0.
    " Only 1 state can produce 1.
    " Only 1 state can produce 2.
    "
    " If 2 states could produce 1, we could NOT use this sum.
    " More generally, we need a bijective, or at least injective, math function,
    " so that no matter the value we get, we can retrieve the exact state
    " which produced it.

    " return an item to display in the statusline
    "
    "        ┌─ no session has been loaded/saved
    "        │     ┌─ a session has been loaded/saved, but isn't tracked
    "        │     │      ┌─ a session is being tracked
    "        │     │      │
    return [ '', '[S]', '[∞]' ][state]
endfu

fu! s:suggest_sessions(arglead, line, _pos) abort "{{{2
    let files = glob(s:session_dir.'/*'.a:arglead.'*.vim', 0, 1)
    return map(files, 'matchstr(v:val, ".*\\.vim/session/\\zs.*\\ze\\.vim")')
endfu

fu! s:track(on_vimleavepre) abort "{{{2
    " This function saves the current session, iff `g:my_session` exists.
    " In the session file, it adds the line:
    "         let g:my_session = v:this_session
    "
    " … so that the next time we load the session, the plugin knows that it must
    " track it automatically.

    if exists('g:SessionLoad')
        " `g:SessionLoad` exists temporarily while a session is loading.
        " See: :h SessionLoad-variable
        "
        " Suppose we source a session file:
        "
        "       :so file
        "
        " During the restoration process, `BufWinEnter` would be fired several
        " times. Every time, the current function would try to update the session
        " file. This would overwrite the file, while it's being used to restore
        " the session. We don't want that.
        "
        " The session file will be updated next time (`BufWinEnter`, `TabClosed`,
        " `VimLeavePre`).

        return ''
    endif

    " update the session  iff / as soon as  this variable exists
    if exists('g:my_session')
        try
            if a:on_vimleavepre
                " empty arglist, we don't want to restore it when we restart Vim
                %argd
            endif
            "             ┌─ overwrite any existing file
            "             │
            exe 'mksession! '.fnameescape(g:my_session)

            "   ┌─ lines of our session file
            "   │
            let body = readfile(g:my_session)

            " add the Ex command:
            "         let g:my_session = v:this_session
            "
            " … just before the last 3 commands:
            "
            "         doautoall SessionLoadPost
            "         unlet SessionLoad
            "         vim: set ft=vim : (modeline)
            call insert(body, 'let g:my_session = v:this_session', -3)
            call writefile(body, g:my_session)

            " Let Vim know that this session is the last used.
            " Useful when we do this:
            "
            "     :STrack        stop the tracking of the current session
            "     :STrack new    create and track a new one
            "     :q             quit Vim
            "     $ vim          restart Vim
            let g:MY_LAST_SESSION = g:my_session

        catch /E788/
            " Since Vim 8.0.677, some autocmds listening to `BufWinEnter`
            " may not work all the time. Sometimes they raise the error `E788`.
            " For us, it happens when we open the qf window (`:copen`).
            " Minimal vimrc to reproduce:
            "
            "         au BufWinEnter * mksession! /tmp/session.vim
            "         copen
            "
            " Basically, `:mksession` (temporarily?) changes the current
            " buffer when 'ft' is set to 'qf', which is now forbidden.
            " For more info, search `E788` on Vim's bug tracker.
            "
            " Here, we simply ignore the error.
            " More generally, when we want to do sth which is forbidden
            " because of a lock, we could use `feedkeys()` and a plug mapping
            " which would execute arbitrary code:
            "     https://github.com/vim/vim/issues/1839#issuecomment-315489118
        catch
            " If sth goes wrong now, it will probably go wrong next time.
            " We don't want to go on trying to save a session, if `default.vim`
            " isn't writable for example.
            unlet! g:my_session

            " update all status lines, to remove the `[∞]` item
            redrawstatus!

            return 'echoerr '.string(v:exception)
        endtry
    endif
    return ''
endfu

fu! s:vim_quit_reload() abort "{{{2
    " Source:
    " https://www.reddit.com/r/vim/comments/5lj75f/how_to_reload_vim_completely_using_zsh_exit_to/
    "
    " For the shell to restart Vim after quitting, we need to add this in `~/.zshrc`:
    "
    "         catch_signal_usr1() {
    "           trap catch_signal_usr1 USR1
    "           clear
    "           vim
    "         }
    "         trap catch_signal_usr1 USR1

    " Send the signal `USR1` to the shell  parent of the current Vim instance to
    " relaunch Vim.
    !kill -USR1 $(ps -p $(ps -p $$ -o ppid=) -o ppid=)
    qa!
endfu

fu! s:where_do_we_save() abort "{{{2
    " :STrack ∅
    if empty(s:file)
        if empty(s:last_used_session)
            if !isdirectory(s:session_dir)
                call mkdir(s:session_dir)
            endif
            return s:session_dir.'/default.vim'
        else
            return s:last_used_session
        endif

    " :STrack dir/
    elseif isdirectory(s:file)
        return fnamemodify(s:file, ':p').'default.vim'

    " :STrack file
    else
        return s:file =~# '/'
        \?         fnamemodify(s:file, ':p')
        \:         s:session_dir.'/'.s:file.'.vim'
    endif
endfu

" Mapping {{{1

nno <silent> <space>R :<c-u>sil call <sid>vim_quit_reload()<cr>
"                            │
"                            └─ bypass prompt:
"                                    “Press ENTER or type command to continue“
"
"                               … after executing the shell command

" Options {{{1
" sessionoptions {{{2

"         ┌─ don't save empty windows when `:mksession` is executed
"         │
"         │           ┌─ only save buffers which are displayed in windows
"         │           │
"         │           │             ┌─ don't save current directory
"         │           │             │  when we start Vim, we want the current directory
"         │           │             │  to be the same as the one in the shell
"         │           │             │  otherwise it can lead to confusing situations when we use `**`
"         │           │             │
set ssop-=blank ssop-=buffers ssop-=curdir ssop-=options
"                                                │
"                                                └─ don't save options and mappings
"                                                   why?
"       because if we make some experiments and change some options/mappings
"       during a session, we don't want those to be restored;
"       only those written in files should be (vimrc, plugins, …)
"
"       EXCEPTION:
"       Vim will  still save folding options,  because we let the  value 'folds'
"       inside 'ssop'.

" viminfo "{{{2

" save and restore global variables that start with an uppercase letter,
" and don't contain a lowercase letter.
" Thus "KEEPTHIS and "K_L_M" are stored, but "KeepThis" and "_K_L_M" are not.
" Nested List and Dict items may not be read back correctly, you end up with an
" empty item.

set viminfo^=!

" Variables {{{1

let s:session_dir = get(s:, 'my_session_dir', $HOME.'/.vim/session')

" Documentation {{{1
" Design {{{2

" `:STrack` can receive 5 kind of names as arguments:
"
"     • nothing
"     • a  new     file (doesn't exist yet)
"     • an empty   file (exists, but doesn't contain anything)
"     • a  regular file
"     • a  session file
"
" Also, `:STrack` can be suffixed with a bang.
" So, we can execute 10 kinds of command in total.
" They almost all track the session.
" This is a DESIGN DECISION (the command could behave differently).
" We design the command so that, by default, it tracks the current session,
" no matter the argument / presence of a bang.
" After all, this is its main purpose.
"
" However, we want to add 2 functionalities:   pause and deletion.
" And we don't want to overwrite an important file by accident.
" These are 3 special cases:
"
"         ┌──────────────────────┬─────────────────────────────────────────┐
"         │ :STrack              │ if the current session is being tracked │
"         │                      │ the tracking is paused                  │
"         ├──────────────────────┼─────────────────────────────────────────┤
"         │ :STrack!             │ if the current session is being tracked │
"         │                      │ the tracking is paused                  │
"         │                      │ AND the session file is deleted         │
"         ├──────────────────────┼─────────────────────────────────────────┤
"         │ :STrack regular_file │ fails (E189)                            │
"         └──────────────────────┴─────────────────────────────────────────┘


" Zen:
"
"     How to write an algorithm composed of 1 main case, and several special cases?
"
"     • chronologically, implement main case  FIRST (special cases later)
"
"     • inside the code, write special cases  BEFORE main case
"
"     • describe EXACTLY the state of the environment when a special case occurs
"
"             - aka necessary and sufficient conditions -
"
"       … and let all the other states be handled by the main case


" Zen: think about the main use case first, THEN the special cases.
" Why?
"
" Here's a metaphor:
" You have to paint a figure inside a sheet. The figure covers most of the sheet.
" It's easier to paint the whole sheet, then remove what's in excess, rather than
" carefully paint the inside without never crossing the boundaries.
"
" Other metaphor:
" To express the number 7, it's easier to read and write:
"
"         ┌─ default action
"         │
"         10 - 1 - 1 - 1
"              │   │   │
"              │   │   └─ …
"              │   └─ special case
"              └─ special case
"
" … than:
"
"         1 + 1 + 1 + 1 + 1 + 1 + 1
"         │   │   │   │   │   │   │
"         │   │   │   │   │   │   └─ …
"         │   │   │   │   │   └─ …
"         │   │   │   │   └─ …
"         │   │   │   └─ …
"         │   │   └─ …
"         │   └─ main case
"         └─ main case
"
" In practice, it means that most of the time, you shouldn't consider the special
" cases before implementing the main use case. For 2 reasons:
"
"         • the final flowchart of your algorithm will be less complex
"
"         • once you have implemented the code for the main use case, you'll have
"           a tool to discover by experimentation the special cases you didn't
"           think about initially

" Usage {{{2

"     • :STrack file
"     • :STrack /path/to/file
"     • :STrack relative/path/to/file
"
" Invoke `:mksession` on:
"
"     • ~/.vim/session/file
"     • /path/to/file
"     • cwd/path/to/file
"
" … iff `file` doesn't exist.
"
" Update the file whenever `BufWinEnter`, `TabClosed` or `VimLeavePre` is fired.


" `:STrack!` invokes `:mksession!`, which tries to overwrite the file no matter what.


"     :STrack dir/
"
" Invoke `:STrack` on `dir/default.vim`.


"     :STrack
"
" If the tracking of a session is running:  pause it
" If the tracking of a session is paused:   resume it
" If no session is being tracked, start tracking the current session in
" ~/.vim/session/default.vim


"     :STrack!
"
" If no session is being tracked, begin the tracking.
" If the tracking of a session is running:  pause it and remove the session
" file.
"
"
" Loading a session created with `:STrack` automatically resumes updates
" to that file.


"     :SDelete!
"     :SRename foo
"
" Delete current session.
" Rename current session into `~/.vim/session/foo`.


"     :SLoad
"
" Load last used session. Useful after `:SClose`.


"     :SLoad#
"     :SDelete!#
"
" Load / Delete the previous session.


"     :SLoad foo
"     :SDelete! foo
"
" Load / Delete session `foo` stored in `~/.vim/session/foo.vim`.


"     :SClose
"
" Close the session:  stop the tracking of the session, and close all windows
