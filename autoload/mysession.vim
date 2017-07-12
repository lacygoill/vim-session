fu! mysession#dispatch(bang, file) abort
    let session = get(g:, 'my_session', v:this_session)

    try
        " `:MS!` was invoked on nothing, `empty(a:file)`, and there's a file session.
        "
        " We probably want to delete the latter.
        " To do so, we'll delete the session file, as well as
        " `g:my_session`.
        " Note the bang after `:unlet`. It's there in case the variable
        " doesn't exist. We don't want error messages.
        if a:bang && empty(a:file) && filereadable(session)
            echo 'Deleting session in '.fnamemodify(session, ':~:.')
            call delete(session)
            unlet! g:my_session
            return ''

        " exists('g:my_session')    →    session = g:my_session
        "
        " g:my_session    + pas de bang    + pas de fichier de session lisible
        " g:my_session    + bang           + pas de fichier de session lisible
        "
        " g:my_session    + pas de bang    + fichier de session lisible
        "
        " `:MS` was invoked on nothing, and `g:my_session` exists.
        " We probably want to pause the recording of the current session.
        " To do so, we simply delete `g:my_session`.
        elseif empty(a:file) && exists('g:my_session')
            echo 'Pausing session in '.fnamemodify(session, ':~:.')
            unlet g:my_session
            return ''

        " :MS was invoked without an argument, but a session has been
        " loaded or written (`v:this_session`).
        " We probably want to update this session (make it persistent).
        " For the moment, we simply store the path to this session file inside
        " `file`.
        elseif empty(a:file) && !empty(session)
            let file = session

        " :MS was invoked without an argument,
        " `g:my_session` doesn't exist,
        " and `v:this_session` is empty.
        "
        " It means that no session is recorded at the moment,
        " and we probably want to prepare one.
        " We need a file for a new session.
        " We'll use `Session.vim` at the root of the working directory.
        elseif empty(a:file)
            if !isdirectory($HOME.'/.vim/session')
                call mkdir($HOME.'/.vim/session')
            endif
            let file = $HOME.'/.vim/session/Session.vim'

        " :MS was invoked with an argument, and it's a directory.
        elseif isdirectory(a:file)
            " We need the full path to `a:file` so we call `fnamemodify()`.
            " But the output of the latter adds a slash (or backslash for
            " Windows) at the end of the path.
            " We want to get rid of it, because we're going to add a path
            " separator just after (`/Session.vim`).
            " So, we also call `substitute()`.
            let file = substitute(fnamemodify(a:file, ':p'), '[\/]$', '', '')
                     \ .'/Session.vim'

        " :MS was invoked with an argument, and it's a file.
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

        let error = s:persist()
        if empty(error)
            echo 'Tracking session in '.fnamemodify(file, ':~:.')
            " Is this line necessary?
            " `s:persist()` should have just created a session file with `:mksession!`.
            " So, `v:this_session` should have been automatically updated by Vim.
            let v:this_session = file
            return ''
        else
            return error
        endif

    finally
        redrawstatus
    endtry
endfu
