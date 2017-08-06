fu! mysession#manual_save(bang, file) abort " {{{1
    let session = get(g:, 'my_session', v:this_session)
    if session ==# ':mksession failed' | let session = '' | endif

    try
        "  ┌ :SessionSave! was invoked
        "  │         ┌ it didn't receive any file as argument
        "  │         │                ┌ there's a readable session file
        "  │         │                │
        if a:bang && empty(a:file) && filereadable(session)
            "  reduce path relative to current working directory ┐
            "                                 don't expand `~` ┐ │
            "                                                  │ │
            echo 'Deleting session in '.fnamemodify(session, ':~:.')

            " remove session file
            call delete(session)

            " disable tracking of the session
            unlet! g:my_session

            " Why empty `v:this_session`?
            " If we don't, then after deleting a session file (:SessionSave!),
            " the next time we try to save a session (:SessionSave), the function
            " will use the file whose path is in `v:this_session` instead of:
            "         ~/.vim/session/Session.vim
            let v:this_session = ''

            return ''

        "      ┌─ :SessionSave didn't receive any file as argument
        "      │                ┌─ the current session is being tracked
        "      │                │
        elseif empty(a:file) && exists('g:my_session')
            echo 'Pausing session in '.fnamemodify(session, ':~:.')
            unlet g:my_session
            " don't empty `v:this_session`: we need it if we resume later
            return ''

        "      ┌─ :SessionSave was invoked without an argument
        "      │                ┌─ a session has been loaded or written
        "      │                │                  ┌─ it's not in the `/tmp` directory
        "      │                │                  │
        elseif empty(a:file) && !empty(session) && session[:3] !=# '/tmp'
        " We probably want to update this session (make it persistent).
        " For the moment, we simply store the path to this session file inside
        " `file`.

            let file = session

        "     :SessionSave was invoked without an argument
        "     no session is being tracked         `g:my_session` doesn't exist
        "     no session has been loaded/saved    `v:this_session` is empty
        "
        " We probably want to prepare the tracking of a session.
        " We need a file for it.
        " We'll use `~/.vim/session/Session.vim`.

        elseif empty(a:file)
            if !isdirectory($HOME.'/.vim/session')
                call mkdir($HOME.'/.vim/session')
            endif
            let file = $HOME.'/.vim/session/Session.vim'

        " :SessionSave dir/
        elseif isdirectory(a:file)
            let file = fnamemodify(a:file, ':p').'Session.vim'

        " :SessionSave file
        else
            let file = fnamemodify(a:file, ':p')
        endif

        if !a:bang
                    \ && file !~# 'Session\.vim$'
                    \ && filereadable(file)
                    \ && getfsize(file) > 0
                    \ && readfile(file, '', 1)[0] !=# 'let SessionLoad = 1'
            return 'mksession '.fnameescape(file)
        endif

        let g:my_session = file

        let cmd = mysession#auto_save()
        if empty(cmd)
            echo 'Tracking session in '.fnamemodify(file, ':~:.')
            return ''
        else
            return cmd
        endif

    finally
        redrawstatus!
    endtry
endfu

fu! mysession#restore(file) abort " {{{1
    let file = !empty(a:file)
             \   ? fnamemodify(a:file, ':p')
             \   : $HOME.'/.vim/session/Session.vim'

    " Don't source the session file if it is:
    "
    "         1. NOT readable
    "         2. already loaded in another Vim instance
    "         3. already loaded in the current instance

    if !filereadable(file)
    \ || s:session_loaded_in_other_instance(file)
    \ || ( exists('g:my_session') && file ==# g:my_session )
        return
    endif

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
    "         noautocmd so ~/.vim/session/Session.vim
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

    exe 'so '.fnameescape(file)

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
    exe 'b '.cur_bufnr
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

fu! s:session_loaded_in_other_instance(file) abort " {{{1
    let some_buffers        = filter(readfile(a:file, '', 20), 'v:val =~# "^badd"')
    if empty(some_buffers)
        return 0
    endif
    let first_buffer        = matchstr(some_buffers[0], '^badd +\d\+ \zs.*')
    let first_file          = fnamemodify(first_buffer, ':p')
    let swapfile_first_file = expand('~/.vim/tmp/swap/').substitute(first_file, '/', '%', 'g').'.swp'
    "                                   ┌─ ignore 'wildignore'
    "                                   │
    if !empty(glob(swapfile_first_file, 1))
        return 1
    endif
endfu
