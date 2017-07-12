" TODO:
" Integrate this:
"         https://github.com/dhruvasagar/vim-prosession

" TODO:
" Add a session item in statusline:
"
"     set stl+=%{My_session_status()}

" Documentation "{{{

" USAGE
"
" :MS {file}              Invoke |:mksession| on {file} and continue to keep it
"                         updated until Vim exits, triggering on the |BufEnter|
"                         and |VimLeavePre| autocommands.  If the file exists,
"                         it will be overwritten if and only if it looks like a
"                         session file.
"
" :MS {dir}               Invoke |:MS| on {dir}/Session.vim.  Use "." to
"                         write to a session file in the current directory.
"
" :MS                     If session tracking is already in progress, pause it.
"                         Otherwise, resume tracking or create a new session in
"                         the current directory.
"
" Loading a session created with |:MS| automatically resumes updates to that file.
"
" STATUS INDICATOR
"
"                                                 My_session_status()
"
" Add %{My_session_status()} to 'statusline', 'tabline', or 'titlestring' to get
" an indicator when our plugin is active or paused.

"}}}
" interface "{{{

"                                       ┌─ My Session
"                                       │
com! -bar -bang -complete=file -nargs=? MS exe mysession#dispatch(<bang>0, <q-args>)

"}}}
" autocmd "{{{

augroup my_session
    au!
    "                              ┌─ if sth goes wrong, the function returns the string:
    "                              │       'echoerr '.string(v:exception)
    "                              │
    "                              │  we need to execute this string
    "                              │
    au BufEnter,VimLeavePre * exe s:persist()
augroup END

"}}}
" s:persist() "{{{

fu! s:persist() abort
    " When `:mksession` creates a session file, it begins with the line:
    "
    "         let SessionLoad = 1
    "
    " And ends with:
    "
    "         unlet SessionLoad
    "
    " So, `g:SessionLoad` exists temporarily while a session is loading.
    " For more info: :h SessionLoad-variable
    "
    " If a session is loading, we don't want `s:persist()` to force the creation
    " of a session file (`:mksession! …`). So, we don't do anything.
    " The session file will be updated next time (`BufEnter`, `VimLeavePre` event).
    if exists('g:SessionLoad')
        return ''
    endif

    if exists('g:my_session')
        try
            " create the session file
            "
            "             ┌─ overwrite any existing file
            "             │
            exe 'mksession! '.fnameescape(g:my_session)

            let body = readfile(g:my_session)
            call insert(body, 'let g:my_session = v:this_session', -3)
            call writefile(body, g:my_session)

        catch
            unlet g:my_session
            redrawstatus
            return 'echoerr '.string(v:exception)
        endtry
    endif
    return ''
endfu

"}}}
" My_session_status() "{{{

fu! My_session_status() abort

    " `state` can have 3 values:
    "
    "         - 0    no session file
    "                (`v:this_session` is empty and `g:my_session` doesn't exist)
    "
    "         - 1    a session has been saved or loaded, but not by our plugin
    "
    "                `v:this_session` is not empty.
    "                Tpope seems to assume that `g:my_session` can't exist
    "                while `v:this_session` is empty.
    "                Right, wrong, or forgotten edge case?
    "
    "         - 2    a session is being recorded by our plugin (`g:my_session` exists)
    let state = !empty(v:this_session) + exists('g:my_session')
    "                  │
    "                  └─ stores the path to the last file which has been used
    "                     to load/save a session;
    "                     if no session has been saved/loaded, it's empty

    return get(['[$]', '[S]'], 2 - state, '')
endfu

"}}}
