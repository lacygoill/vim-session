fu! mysession#handle_session_file(bang, file) abort " {{{1
    " exists('g:my_session')    →    session = g:my_session
    "
    " g:my_session    + pas de bang    + pas de fichier de session lisible
    " g:my_session    + bang           + pas de fichier de session lisible
    "
    " g:my_session    + pas de bang    + fichier de session lisible
    let session = get(g:, 'my_session', v:this_session)

    try
        "  ┌ :MSV! was invoked
        "  │         ┌ it didn't receive any file as argument
        "  │         │                ┌ there's a readable session file
        "  │         │                │
        if a:bang && empty(a:file) && filereadable(session)
            "       reduce path relative to current working directory ┐
            "                                      don't expand `~` ┐ │
            "                                                       │ │
            echo '[MS] Deleting session in '.fnamemodify(session, ':~:.')

            " remove session file
            call delete(session)

            " disable tracking of the session
            unlet! g:my_session

            " TODO:
            " Should we empty `v:this_session`?
            " If we don't, then after deleting a session file (:MSV!), the next time we
            " try to save a session (:MSV), the plugin will use the file stored in
            " `v:this_session` instead of the default path `~/.vim/session/Session.vim`.
            " Do we want that?
            let v:this_session = ''

            return ''

        "      ┌─ :MSV didn't receive any file as argument
        "      │                ┌─ the current session is being tracked
        "      │                │
        elseif empty(a:file) && exists('g:my_session')
            echo '[MS] Pausing session in '.fnamemodify(session, ':~:.')
            unlet g:my_session
            " don't empty `v:this_session`: we need it if we resume later
            return ''

        "      ┌─ :MSV was invoked without an argument
        "      │                ┌─ a session has been loaded or written
        "      │                │                  ┌─ it's not in the `/tmp` directory
        "      │                │                  │
        elseif empty(a:file) && !empty(session) && session[:3] !=# '/tmp'
        " We probably want to update this session (make it persistent).
        " For the moment, we simply store the path to this session file inside
        " `file`.

            let file = session

        "     :MSV was invoked without an argument
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

        " :MSV was invoked with an argument, and it's a directory.
        elseif isdirectory(a:file)
            let file = fnamemodify(a:file, ':p').'Session.vim'

        " :MSV was invoked with an argument, and it's a file.
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

        let msg = mysession#persist()
        if empty(msg)
            echo '[MS] Tracking session in '.fnamemodify(file, ':~:.')
            " Is this line necessary?
            " `persist()` should have just created a session file with `:mksession!`.
            " So, `v:this_session` should have been automatically updated by Vim.
            " Update:
            " Read the code of `persist()`; it may fail to create a session
            " file.
            let v:this_session = file
            return ''
        else
            return msg
        endif

    finally
        redrawstatus!
    endtry
endfu

fu! mysession#restore(file) abort " {{{1
    let file = !empty(a:file)
             \   ? fnamemodify(a:file, ':p')
             \   : expand('~/.vim/session/Session.vim')

    " Prevent `:MSR` from loading a session if:
    "
    "         1. the session file is NOT readable
    "         2. we execute `:MSR` twice by accident:
    "
    "             :MSR  ✔
    "             :MSR  ✘
    "
    " It shouldn't reload any session unless no session is being tracked, or we
    " give it an explicit argument (filepath).

    if !filereadable(file)
    \ || (exists('g:my_session') && ( empty(file) || file ==# g:my_session ))
    \ || s:session_loaded_in_other_instance(file)

       " TODO:
       "
       "    The final / total condition should be:
       "
       "            :MSR shouldn't load a session unless no session is being tracked,
       "            or we give it an explicit path which is different than the one of
       "            the file of the current tracked session
       "
       "    Rewrite our comments relative to the condition, to reflect that:
       "    summarize them, make them more readable.
       "
       "    TODO:
       "    I don't know exactly if `a:file` and `g:my_session` are relative
       "    or absolute paths. `a:file` could be either, it depends on what
       "    the user typed after `:MSR`. For, `g:my_session`, I really don't
       "    know. I suspect it can be both.
       "    We need to normalize both of them (absolute path), so that the
       "    comparison:
       "            g:my_session ==# a:file
       "
       "    … is reliable.
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
    "           → no syntax highlighting
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

    " The next commands (in particular `:tabdo windo`) may leave us in a new window.
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
    " But the purpose of some of our them is to set WINDOW-local options.
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

    " restore syntax highlighting in help files
    sil! bufdo if expand('%') =~# '^'.$VIMRUNTIME.'/doc/.*\.txt'
            \|     call s:restore_help_settings()
            \| endif

    call win_gotoid(cur_winid)
endfu

fu! s:restore_help_settings() abort "{{{1
    " FIXME:
    " Isn't there a simpler solution?
    " Vim doesn't rely on an autocmd to restore the settings of a help buffer.
    " Confirmed by typing:         au * <buffer=42>
    "
    " If we reload a help buffer, without installing an autocmd to restore the
    " filetype, the latter gets back to `text`.
    " If we re-open the file with the right `:h tag`, it opens a new window,
    " with the same `text` file. From there, if we reload the file, it gets
    " back to `help` in both windows. It happens with and without the previous
    " command. Here are the events fired by `:h`:
    "
    "       BufUnload
    "       BufReadPre
    "       Syntax
    "       FileType
    "       BufRead
    "       BufReadPost
    "       Syntax
    "       FileType
    "       BufEnter
    "       BufWinEnter
    "       TextChanged

    setl ft=help nobuflisted noma ro

    augroup restore_help_settings
        au! * <buffer>
        au BufRead <buffer> setl ft=help nobuflisted noma ro
    augroup END
endfu

fu! s:session_loaded_in_other_instance(file) abort " {{{1
    let some_lines          = readfile(a:file, '', 20)
    let first_buffer        = matchstr(filter(some_lines, 'v:val =~# "^badd"')[0], '^badd +\d\+ \zs.*')
    let first_file          = fnamemodify(first_buffer, ':p')
    let swapfile_first_file = expand('~/.vim/tmp/swap/').substitute(first_file, '/', '%', 'g').'.swp'
    if !empty(glob(swapfile_first_file, 1))
        return 1
    endif
endfu
