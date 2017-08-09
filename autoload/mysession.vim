fu! s:delete_session() abort "{{{1
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

fu! s:file_is_valuable() abort "{{{1
    " `:mksession file` fails, because it refuses to overwrite an existing file.
    " `:STrack` should behave the same way.
    " With one exception:  if the file isn't valuable, overwrite it anyway.
    "
    " What does a valuable file look like? :
    "
    "         - readable
    "         - not empty
    "         - doesn't look like a session file
    "           because neither the name nor the contents match

    if !s:bang
                \ && filereadable(s:file)
                \ && getfsize(s:file) > 0
                \ && s:file !~# 'default\.vim$'
                \ && readfile(s:file, '', 1)[0] !=# 'let SessionLoad = 1'
        return 1
    endif

    " What about `:STrack! file`?
    " `:mksession! file` overwrites `file`.
    " `:STrack!` should do the same, which is why this function will
    " return 0 if a bang was given.

    " Zen:
    " When you implement a new feature, always make it behave like the existing
    " ones. Don't add inconsistency.
endfu

fu! mysession#handle_session(bang, file) abort " {{{1
    " We move `a:bang`, `a:file` , and put `s:last_used_session` into the
    " script-local scope, to not have to pass them as arguments to various
    " functions:
    "
    "         s:should_delete_session()
    "         s:delete_session()
    "         s:should_pause_session()
    "         s:pause_session()
    "         s:where_do_we_save()
    "         s:file_is_valuable()

    let s:bang = a:bang
    let s:file = a:file
    let s:last_used_session = get(g:, 'my_session', v:this_session)

    try
        " `:STrack` should behave mostly like `:mksession` with the
        " additional benefit of updating the session file.
        "
        " However, we want 2 additional features:  deletion and pausing.

        " The conditions to delete and to pause a session could be satisfied
        " simultaneously. That happens when:
        "
        "         - a bang was used
        "         - no file was given
        "         - a session has already been saved / written
        "         - a session is being tracked
        "
        " In this case, we WANT (!=need) to delete the session file that was
        " last used, and try to stop the tracking of the current session if
        " there's one. So, we check first `should_delete_session()`, THEN
        " `should_pause_session()`.
        "
        " We give priority to deletion over pausing, because it fits our
        " intuition. A bang should mean deletion.

        if s:should_delete_session()
            return s:delete_session()
        elseif s:should_pause_session()
            return s:pause_session()
        endif

        let s:file = s:where_do_we_save()
        if empty(s:file) | return '' | endif
        if s:file_is_valuable() | return 'mksession '.fnameescape(s:file) | endif
        "                                └──────────────────────────────┤
        "                                                               │
        " We don't want to raise an error from the current function (ugly stack trace).
        " The user only knows about `:mksession`, so the error must look like
        " it's coming from the latter.
        " We just return 'mksession file'. It will be executed outside this function,
        " fail, and produce the “easy-to-read“ error message:
        "
        "         E189: "file" exists (add ! to override)

        let g:my_session = s:file
        " let `track()` know that it must save & track the current session

        let error = mysession#track()
        if empty(error)
            echo 'Tracking session in '.fnamemodify(s:file, ':~:.')
            return ''
        else
            return error
        endif

    finally
        redrawstatus!
        unlet! s:bang s:file s:last_used_session
    endtry
endfu

fu! s:pause_session() abort "{{{1
    echo 'Pausing session in '.fnamemodify(s:last_used_session, ':~:.')
    unlet g:my_session
    " don't empty `v:this_session`: we need it if we resume later
    return ''
endfu

fu! s:rename_tmux_window(file) abort "{{{1
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

fu! mysession#restore(file) abort " {{{1

    let file = empty(a:file)
                \ ? $HOME.'/.vim/session/default.vim'
                \ : a:file =~# '/'
                \     ? fnamemodify(a:file, ':p')
                \     : $HOME.'/.vim/session/'.a:file.'.vim'

    " Don't source the session file if it is:
    "
    "         1. NOT readable
    "         2. already loaded

    if !filereadable(file)
    \ || ( exists('g:my_session') && file ==# g:my_session )
        return
    endif
    " NOTE: old additional condition {{{
    "
    " The next condition would be useful to prevent our autocmd which invokes
    " `SLoad` from automatically sourcing the same session in 2 different
    " Vim instances (which would give warning messages because of the swap
    " files):
    "
    "         \ || s:session_loaded_in_other_instance(file)
    "
    " But contrary to the name of the function, it can only detect whether
    " a session has already been loaded in a still-running Vim instance.
    " It can't detect whether the session is loaded in another Vim instance,
    " or in the current one.
    " Besides, it can be useful to switch from a session to another, and come
    " back later to the original session. This condition would prevent that,
    " because it would wronlgy assume that the session has been loaded in
    " another Vim instance."}}}

    " If we switch from a session with several tabpages, to another one with
    " just one, all the tabpages from the 1st session (except the first tabpage)
    " are transferred to the new session.
    sil! tabonly | sil! only
    "  │
    "  └─ if there's already only 1 tab, it will display a message

    exe 'so '.fnameescape(file)
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

    " The next command may leave us in a new window.
    " We need to save our current position, to restore it later.
    let cur_winid = win_getid()

    " We fire `BufWinEnter` in all windows to apply window-local options in
    " all opened windows. Also, it may be useful to position us at the end of
    " the changelist (through our autocmd my_changelist which listens to this
    " event).

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

    tabdo windo sil! doautocmd BufWinEnter
    " │   │        │
    " │   │        └─ we don't want an error to interrupt the process
    " │   └─ iterate over windows
    " └─ iterate over tabpages

    call win_gotoid(cur_winid)

    " restore syntax highlighting in help files

    " `:bufdo` is executed in the context of the last window of the last tabpage.
    " Thus, it could replace its buffer with another buffer (the one with the
    " biggest number).
    let cur_bufnr = bufnr('%')
    sil! bufdo if expand('%') =~# '^'.$VIMRUNTIME.'/doc/.*\.txt'
            \|     call s:restore_help_settings()
            \| endif
    " I had a `E86` error once (buffer didn't exist anymore).
    if bufexists(cur_bufnr)
        exe 'b '.cur_bufnr
    endif

    call s:rename_tmux_window(file)
endfu

fu! s:restore_help_settings() abort "{{{1
    " For some reason, Vim doesn't restore some settings in a help buffer,
    " including the syntax highlighting.

    setl ft=help nobuflisted noma ro

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

" fu! s:session_loaded_in_other_instance(file) abort " {{{1
"     let some_buffers        = filter(readfile(a:file, '', 20), 'v:val =~# "^badd"')
"
"     if empty(some_buffers)
"         return 0
"     endif
"
"     let first_buffer        = matchstr(some_buffers[0], '^badd +\d\+ \zs.*')
"     let first_file          = fnamemodify(first_buffer, ':p')
"     let swapfile_first_file = expand('~/.vim/tmp/swap/').substitute(first_file, '/', '%', 'g').'.swp'
"
"     "                                   ┌─ ignore 'wildignore'
"     "                                   │
"     if !empty(glob(swapfile_first_file, 1))
"         return 1
"     endif
" endfu

fu! s:should_delete_session() abort "{{{1
    "                        ┌ :STrack! ø
    "  ┌─────────────────────┤
    if s:bang && empty(s:file) && filereadable(s:last_used_session)
    "                             │
    "                             └─ a session file was used and its file is readable
        return 1
    endif
endfu

fu! s:should_pause_session() abort "{{{1
    "  ┌─ :STrack ø
    "  │                ┌─ the current session is being tracked
    "  │                │
    if empty(s:file) && exists('g:my_session')
        return 1
    endif
endfu

fu! mysession#suggest_sessions(lead, line, _pos) abort "{{{1
    let dir   = $HOME.'/.vim/session/'
    let files = glob(dir.'*'.a:lead.'*', 0, 1)
    return map(files, 'matchstr(v:val, ".*\\.vim/session/\\zs.*\\ze\\.vim")')
endfu

fu! s:where_do_we_save() abort "{{{1

    " :STrack ø
    if empty(s:file)
        if !empty(s:last_used_session)
            return s:last_used_session
        else
            if !isdirectory($HOME.'/.vim/session')
                call mkdir($HOME.'/.vim/session')
            endif
            return $HOME.'/.vim/session/default.vim'
        endif

    " :STrack dir/
    elseif isdirectory(s:file)
        return fnamemodify(s:file, ':p').'default.vim'

    " :STrack file
    else
        return s:file =~# '/'
                    \ ? fnamemodify(s:file, ':p')
                    \ : 'session/'.s:file.'.vim'
    endif
endfu
