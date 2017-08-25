" Autocmds {{{1

augroup my_session
    au!
    au StdInReadPost * let s:read_stdin = 1

    "             ┌─ necessary to source ftplugins (trigger autocmds listening to bufread event?)
    "             │
    au VimEnter * nested if s:safe_to_load_session()
                      \|     exe 'SLoad '.get(g:, 'MY_LAST_SESSION', 'default')
                      \| endif

    " NOTE: The next autocmd serves 2 purposes:
    "
    "     1. automatically save the current session, as soon as `g:my_session`
    "        pops into existence
    "
    "     2. update the session file frequently, and as long as `g:my_session` exists
    "        IOW, track the session

    "                            ┌─ if sth goes wrong, the function returns the string:
    "                            │       'echoerr '.string(v:exception)
    "                            │
    "                            │  we need to execute this string
    "                            │
    au BufWinEnter,VimLeavePre * exe s:track()
    "  │
    "  └─ We don't want the session to be saved only when we quit Vim,
    "     because Vim could exit abnormally.
    "
    "     NOTE:
    "     Contrary to `BufEnter`, `BufWinEnter` is NOT fired for `:split`
    "     (without arguments), nor for `:split file`, file being already
    "     displayed in a window.
    "
    "     But most of the time, Vim won't quit abnormally, and the last saved
    "     state of our session will be performed when VimLeavePre is fired.
    "     So, `VimLeavePre` will have the final say most of the time.

    au TabClosed * call timer_start(0, {-> execute('exe '.s:snr().'track()')})
    " We also save whenever we close a tabpage, because we don't want
    " a closed tabpage to be restored while we switch back and forth between
    " 2 sessions with `:SLoad`.
    " But, we can't save the session immediately, because for some reason, Vim
    " would only save the last tabpage (or the current one?). So, we delay the
    " saving.
augroup END

" Commands {{{1

" NOTE: Why `exe s:handle_session()` {{{
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

com! -bar -bang -nargs=? -complete=file                          STrack   exe s:handle_session(<bang>0, <q-args>)
com! -bar       -nargs=? -complete=customlist,s:suggest_sessions SLoad    exe s:load(<q-args>)
com! -bar       -nargs=1 -complete=customlist,s:suggest_sessions SRename  echoerr s:rename(<q-args>)

" Functions "{{{1
fu! s:file_is_valuable() abort "{{{2
    " By default, `:mksession file` fails, because `:mksession` refuses to overwrite
    " an existing file.
    " `:STrack` should behave the same way.
    " With one exception:  if the file isn't valuable, overwrite it anyway.
    "
    " What does a valuable file look like? :
    "
    "         - readable
    "         - not empty
    "         - doesn't look like a session file, because
    "           neither its location nor its contents match

    return filereadable(s:file)
      \&&  getfsize(s:file) > 0
      \&&  fnamemodify(s:file, ':h')  !=# s:session_dir
      \&&  readfile(s:file, '', 1)[0] !=# 'let SessionLoad = 1'
endfu

fu! s:handle_session(bang, file) abort " {{{2
    " We move `a:bang`, `a:file` , and put `s:last_used_session` into the
    " script-local scope, to NOT have to pass them as arguments to various
    " functions:
    "
    "         s:should_delete_session()
    "         s:session_delete()
    "         s:should_pause_session()
    "         s:session_pause()
    "         s:where_do_we_save()
    "         s:file_is_valuable()

    let s:bang = a:bang
    let s:file = a:file
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

        "  ┌─ we only care whether a file is valuable if NO bang is given
        "  │
        "  │  Otherwise, we overwrite the file no matter what.
        "  │  `:mksession! file` overwrites `file`. `:STrack!` should do the same.
        "  │
        if !s:bang && s:file_is_valuable() | return 'mksession '.fnameescape(s:file) | endif
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
        " when we track a new session.
        let error = s:track()
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

fu! s:load(file) abort " {{{2
    "   ┌─ 1st restoration:  1    !(-1 + 1)
    "   │  2nd "          :  0    !(1 + 1)
    "   │  3rd "          :  0    !(0 + 1)
    "   │  …
    let s:first_restoration = !(get(s:, 'first_restoration', -1) + 1)
    " How did we find the formula?
    " Simple solution, use a counter:
    "
    "         let s:counter += get(s:, 'counter', 0) + 1
    "
    " Pb: all the values of the counter will be true.
    " Solution: start counting from -1, instead of 0.
    "
    "         let s:counter += get(s:, 'counter', -1) + 1
    "
    " Pb: the 1st value will be false, the next ones will be true.
    " We need the opposite.
    " Solution: invert the value.
    "
    "         let s:counter += !(get(s:, 'counter', -1) + 1)

    let file = empty(a:file)
            \?     s:session_dir.'/default.vim'
            \: a:file ==# '#'
            \?     g:MY_PENULTIMATE_SESSION
            \: a:file =~# '/'
            \?     fnamemodify(a:file, ':p')
            \:     s:session_dir.'/'.a:file.'.vim'

    let file = resolve(file)

    if !filereadable(file)
        return 'echoerr '.string(fnamemodify(file, ':t')).'." doesn''t exist, or it''s not readable"'
    elseif s:session_loaded_in_other_instance(file)
        return 'echoerr '.string(fnamemodify(file, ':t')).'." is already loaded in another Vim instance"'
    elseif exists('g:my_session') && file ==# g:my_session
        return 'echoerr '.string(fnamemodify(file, ':t')).'." is already the current session"'
    endif

    call s:prepare_restoration(file)

    " Even though we don't include 'options' inside 'ssop', a session file
    " manipulates the value of 'shm'. We save and restore this option
    " manually, to be sure it won't be changed. It happened once:
    " 'shm' was constantly emptied by all session files.
    let shm_save = &shm

    " Before restoring a session, we need to set the previous one (for `:SLoad#`).
    " The previous one is:
    "         - the current tracked session, if there's one
    "         - or the last tracked session, "
    if exists('g:my_session')
        let g:MY_PENULTIMATE_SESSION = g:my_session
    " If we've paused the tracking of a session, `g:my_session` won't exist.
    " But, `g:MY_LAST_SESSION` still exists. Use it as the alternative
    " session, but not during Vim's startup (otherwise we would lose the
    " alternative session whenever we start Vim).
    elseif exists('g:MY_LAST_SESSION') && !s:first_restoration
        let g:MY_PENULTIMATE_SESSION = g:MY_LAST_SESSION
    endif

    "  ┌─ Sometimes, when the session contains one of our folded notes,
    "  │  an error is raised. It seems some commands, like `zo`, fail to
    "  │  manipulate a fold, because it doesn't exist. Maybe the buffer is not
    "  │  folded yet.
    "  │
    sil! exe 'so '.fnameescape(file)
    " NOTE: possible issue with other autocmds {{{
    "
    " Every custom function that we invoke in any autocmd (vimrc, other plugin)
    " may interfere with the restoration process.
    " For an example, have a look at `s:dnb_clean()` in vimrc.
    "
    " To prevent any issue, we could restore the session while all autocmds are
    " disabled, THEN emit the `BufRead` event in all buffers, to execute the
    " autocmds associated to filetype detection:
    "
    "         noautocmd so ~/.vim/session/default.vim
    "         doautoall filetypedetect BufRead
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
    "       `doautoall filetypedetect BufRead` would only affect the file in
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

    call s:restore_window_local_settings()
    call s:restore_help_settings_when_needed()
    call s:rename_tmux_window(file)
    return ''
endfu

fu! s:prepare_restoration(file) abort "{{{2
    " Update current session file, before loading another one.
    exe s:track()

    call writefile(filter(readfile(a:file), 'v:val !~# "^argadd "'), a:file)
    "                                        └──────────────────┤
    "                                                           └ get rid of arglist
    "                                                             we don't want to restore it

    " If we switch from a session with several tabpages, to another with just one,
    " all the tabpages from the 1st session (except the first tabpage)
    " stay in the new session. We don't want that.
    sil! tabonly | sil! only
    "  │
    "  └─ if there's already only 1 tab, it will display a message
endfu

fu! s:rename(new_name) abort "{{{2
    let src = g:my_session
    let dst = expand(s:session_dir.'/'.a:new_name.'.vim')

    if rename(src, dst)
        return 'Failed to rename '.string(src).' to '.string(dst)
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
        au BufRead <buffer> setl ft=help nobuflisted noma ro
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

    " NOTE:
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

    " I had a `E86` error once (buffer didn't exist anymore).
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
    " Because `:doautoall` executes the autocmds in the context of the buffers.
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
       \&& !s:session_loaded_in_other_instance(get(g:, 'MY_LAST_SESSION', 'default'))

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

fu! s:session_loaded_in_other_instance(session_file) abort " {{{2
    let buffers = filter(readfile(a:session_file), 'v:val =~# "^badd"')

    if empty(buffers)
        return 0
    endif

    " NOTE: Never assign to a variable, the output of a function which operates{{{
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
    return a_file_is_currently_loaded && it_is_not_in_this_session
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
    let g:MY_PENULTIMATE_SESSION = g:my_session
    unlet g:my_session
    " don't empty `v:this_session`: we need it if we resume later
    return ''
endfu

fu! s:should_delete_session() abort "{{{2
    "                            ┌ :STrack! ø
    "      ┌─────────────────────┤
    return s:bang && empty(s:file) && filereadable(s:last_used_session)
    "                                 │
    "                                 └─ a session file was used and its file is readable
endfu

fu! s:should_pause_session() abort "{{{2
    "      ┌─ no bang
    "      │          ┌─ :STrack ø
    "      │          │                ┌─ the current session is being tracked
    "      │          │                │
    return !s:bang && empty(s:file) && exists('g:my_session')
endfu

fu! s:snr() "{{{2
    return matchstr(expand('<sfile>'), '<SNR>\d\+_')
endfu

fu! mysession#status() abort "{{{2

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
    " NOTE:
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

fu! s:suggest_sessions(lead, line, _pos) abort "{{{2
    let files = glob(s:session_dir.'/*'.a:lead.'*.vim', 0, 1)
    return map(files, 'matchstr(v:val, ".*\\.vim/session/\\zs.*\\ze\\.vim")')
endfu

fu! s:track() abort "{{{2
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

fu! s:where_do_we_save() abort "{{{2
    " :STrack ø
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
            \?     fnamemodify(s:file, ':p')
            \:     s:session_dir.'/'.s:file.'.vim'
    endif
endfu

" Usage {{{1

"     :STrack file
"
" Invoke `:mksession` on `file`, iff `file`:
"
"     • doesn't exist
"     • is empty
"     • looks like a session file (according to its name or its contents)
"
" Update the file whenever `BufWinEnter`, `TabClosed` or `VimLeavePre` is fired.
"
"
"     :STrack dir
"
" Invoke `:STrack` on `dir/default.vim`.
"
"
"     :STrack
"
" If the tracking of a session is running:  pause it
" If the tracking of a session is paused:   resume it
" If no session is being tracked, start tracking the current session in
" ~/.vim/session/default.vim
"
"
"     :STrack!
"
" If no session is being tracked, begin the tracking.
" If the tracking of a session is running:  cancel it and remove the session
" file.
"
"
" Loading a session created with `:STrack` automatically resumes updates
" to that file.
"
"
"     :SLoad#
"
" Load the previous session.

" Variables {{{1

let s:session_dir = get(s:, 'my_session_dir', $HOME.'/.vim/session')
