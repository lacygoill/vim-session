" restore {{{1

fu! mysession#restore(file) abort
    " Prevent `:MSR` from loading a session if we execute it twice by accident:
    "
    "     :MSR  ✔
    "     :MSR  ✘
    "
    " It shouldn't reload any session unless no session is being tracked, or we
    " give it an explicit argument (filepath).

    if      ( !empty(get(g:, 'my_session', '')) && empty(a:file)           )
       \ || (  exists('g:my_session')           && g:my_session ==# a:file )
       " │
       " └─ Add an extra guard. It shouldn't reload a session if one is being tracked,
       "    and we ask to reload the same.
       "
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

    " Every custom function that we invoke in any autocmd (vimrc, other plugin)
    " could cause an issue while we restore a session with `:so`.
    " For an example, have a look at `s:dnb_clean()` in vimrc.
    "
    " `:MSR` invokes this function to workaround this issue.
    " It restores the session, while all autocmds are disabled, THEN
    " it emits the `BufRead` event in all buffers, to execute the autocmds
    " associated to filetype detection.

    " FIXME:
    "
    "  ┌─ E490: No fold found
    "  │  happens when one of our buffers is a markdown note, without a proper extension `.md`
    "  │
    "  │  I'm not sure the pb is the filetype. Even our note buffer is
    "  │  restored and the filetype properly detected, sometimes (always?) we
    "  │  still don't have any folds. How does Vim apply folding?
    "  │  What prevents Vim from folding a buffer initially? The wrong filetype?
    "  │
    sil! exe 'noautocmd so '
        \ . (!empty(a:file) ? fnameescape(a:file) : '~/.vim/session/Session.vim')
        \ | doautoall filetypedetect BufRead
        "             │
        "             └─ $VIMRUNTIME/filetype.vim

    " FIXME:
    " Is the `BufRead` event inside the `filetypedetect` augroup enough?
    " Are there autocmds which won't be fired, but should?
    " It could happen.
    "
    " When we save a session, containing one of our folded markdown notes,
    " `:mksession` saves the state of the folds (open/closed).
    " When we restore the session, Vim throws the error:
    "         E490: No fold found
    "
    " Probably because at the time they are loaded, they don't have the
    " 'markdown' filetype yet. Our custom ftdetect autocmd hasn't fired yet.
    " And so, there're no folds. Confirmed by the fact that there're no errors
    " if we do `:sav mynotes /tmp/mynotes.md`, then quit with `mynotes.md`
    " displayed instead of `mynotes`.
    "
    " Conclusion:
    " If the state of our buffers, at the time they they are saved, is different
    " from the one they are in when we restore them, there can be errors.
endfu

" handle_session_file {{{1

" exists('g:my_session')    →    session = g:my_session
"
" g:my_session    + pas de bang    + pas de fichier de session lisible
" g:my_session    + bang           + pas de fichier de session lisible
"
" g:my_session    + pas de bang    + fichier de session lisible
fu! mysession#handle_session_file(bang, file) abort
    let session = get(g:, 'my_session', v:this_session)

    try
        "  ┌ :MSR! was invoked
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

            return ''

        "      ┌─ :MSR didn't receive any file as argument
        "      │                ┌─ the current session is being tracked
        "      │                │
        elseif empty(a:file) && exists('g:my_session')
            echo '[MS] Pausing session in '.fnamemodify(session, ':~:.')
            unlet g:my_session
            return ''

        "      ┌─ :MSR was invoked without an argument
        "      │                ┌─ a session has been loaded or written
        "      │                │                  ┌─ it's not in the `/tmp` directory
        "      │                │                  │
        elseif empty(a:file) && !empty(session) && session[:3] !=# '/tmp'
        " We probably want to update this session (make it persistent).
        " For the moment, we simply store the path to this session file inside
        " `file`.

            let file = session

        "     :MSR was invoked without an argument
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

        " :MSR was invoked with an argument, and it's a directory.
        elseif isdirectory(a:file)
            " We need the full path to `a:file` so we call `fnamemodify()`.
            " But the output of the latter adds a slash at the end of the path.
            " We want to get rid of it, because we're going to add a path
            " separator just after (`/Session.vim`).
            " So, we also call `substitute()`.
            let file = substitute(fnamemodify(a:file, ':p'), '/$', '', '')
                     \ .'/Session.vim'

        " :MSR was invoked with an argument, and it's a file.
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
            let v:this_session = file
            return ''
        else
            return msg
        endif

    finally
        redrawstatus!
    endtry
endfu
