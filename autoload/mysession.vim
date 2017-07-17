" exists('g:my_session')    →    session = g:my_session
"
" g:my_session    + pas de bang    + pas de fichier de session lisible
" g:my_session    + bang           + pas de fichier de session lisible
"
" g:my_session    + pas de bang    + fichier de session lisible
fu! mysession#handle_session_file(bang, file) abort
    let session = get(g:, 'my_session', v:this_session)

    try
        "  ┌ :MS! was invoked
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

        "      ┌─ :MS didn't receive any file as argument
        "      │                ┌─ the current session is being tracked
        "      │                │
        elseif empty(a:file) && exists('g:my_session')
            echo '[MS] Pausing session in '.fnamemodify(session, ':~:.')
            unlet g:my_session
            return ''

        "      ┌─ :MS was invoked without an argument
        "      │                ┌─ a session has been loaded or written
        "      │                │                  ┌─ it's not in the `/tmp` directory
        "      │                │                  │
        elseif empty(a:file) && !empty(session) && session[:3] !=# '/tmp'
        " We probably want to update this session (make it persistent).
        " For the moment, we simply store the path to this session file inside
        " `file`.

            let file = session

        "     :MS was invoked without an argument
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

        " :MS was invoked with an argument, and it's a directory.
        elseif isdirectory(a:file)
            " We need the full path to `a:file` so we call `fnamemodify()`.
            " But the output of the latter adds a slash at the end of the path.
            " We want to get rid of it, because we're going to add a path
            " separator just after (`/Session.vim`).
            " So, we also call `substitute()`.
            let file = substitute(fnamemodify(a:file, ':p'), '/$', '', '')
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
