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

    " Even though we don't include 'options' inside 'ssop', a session file
    " manipulates the value of 'shm'. We save and restore this option
    " manually, to be sure it won't be changed. It happened once:
    " 'shm' was constantly emptied by all session files.
    let shm_save = &shm
    "  ┌─ Sometimes, when one of the session contains one of our folded notes,
    "  │  an error is raised. It seems some commands, like `zo`, fail to
    "  │  manipulate a fold, because it doesn't exist. Maybe, the buffer is not
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
    let g:MY_LAST_SESSION = fnamemodify(g:my_session, ':t:r')

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
    sil! bufdo if expand('%') =~# '/doc/.*\.txt$'
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
"     "                                          ┌─ ignore 'wildignore'
"     "                                          │
"     return if !empty(glob(swapfile_first_file, 1))
" endfu

fu! mysession#suggest_sessions(lead, line, _pos) abort "{{{1
    let dir   = $HOME.'/.vim/session/'
    let files = glob(dir.'*'.a:lead.'*', 0, 1)
    return map(files, 'matchstr(v:val, ".*\\.vim/session/\\zs.*\\ze\\.vim")')
endfu

