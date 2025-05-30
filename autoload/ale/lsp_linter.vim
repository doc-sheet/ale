" Author: w0rp <devw0rp@gmail.com>
" Description: Integration between linters and LSP/tsserver.

" This code isn't loaded if a user never users LSP features or linters.

" Associates LSP connection IDs with linter names.
if !has_key(s:, 'lsp_linter_map')
    let s:lsp_linter_map = {}
endif

" Clear LSP linter data for the linting engine.
function! ale#lsp_linter#ClearLSPData() abort
    let s:lsp_linter_map = {}
endfunction

" Only for internal use.
function! ale#lsp_linter#GetLSPLinterMap() abort
    return s:lsp_linter_map
endfunction

" Just for tests.
function! ale#lsp_linter#SetLSPLinterMap(replacement_map) abort
    let s:lsp_linter_map = a:replacement_map
endfunction

" A map for tracking URIs for diagnostic request IDs
if !has_key(s:, 'diagnostic_uri_map')
    let s:diagnostic_uri_map = {}
endif

" For internal use only.
function! ale#lsp_linter#ClearDiagnosticURIMap() abort
    let s:diagnostic_uri_map = {}
endfunction

" For internal use only.
function! ale#lsp_linter#GetDiagnosticURIMap() abort
    return s:diagnostic_uri_map
endfunction

" Just for tests.
function! ale#lsp_linter#SetDiagnosticURIMap(replacement_map) abort
    let s:diagnostic_uri_map = a:replacement_map
endfunction

" Get all enabled LSP linters.
" This list still includes linters ignored with `ale_linters_ignore`.
"
" `ale_linters_ignore` is designed to allow language servers to be used for
" their functionality while ignoring the diagnostics they return.
function! ale#lsp_linter#GetEnabled(buffer) abort
    let l:filetype = getbufvar(a:buffer, '&filetype')
    " Only LSP linters are included here.
    let l:linters = filter(ale#linter#Get(l:filetype), '!empty(v:val.lsp)')
    let l:disable_lsp = ale#Var(a:buffer, 'disable_lsp')

    " Only load code for ignoring linters if we need it.
    if (
    \   l:disable_lsp is 1
    \   || l:disable_lsp is v:true
    \   || (l:disable_lsp is# 'auto' && get(g:, 'lspconfig', 0))
    \)
        let l:linters = ale#engine#ignore#Exclude(
        \   l:filetype,
        \   l:linters,
        \   [],
        \   l:disable_lsp,
        \)
    endif

    return l:linters
endfunction

" Check if diagnostics for a particular linter should be ignored.
function! s:ShouldIgnoreDiagnostics(buffer, linter) abort
    let l:config = ale#Var(a:buffer, 'linters_ignore')
    let l:disable_lsp = ale#Var(a:buffer, 'disable_lsp')

    " Only load code for ignoring linters if we need it.
    if (
    \   !empty(l:config)
    \   || l:disable_lsp is 1
    \   || l:disable_lsp is v:true
    \   || (l:disable_lsp is# 'auto' && get(g:, 'lspconfig', 0))
    \)
        " Re-use the ignore implementation just for this linter.
        return empty(
        \   ale#engine#ignore#Exclude(
        \       getbufvar(a:buffer, '&filetype'),
        \       [a:linter],
        \       l:config,
        \       l:disable_lsp,
        \   )
        \)
    endif

    return 0
endfunction

" Handle LSP diagnostics for a given URI.
" The special value 'unchanged' can be used for diagnostics to indicate
" that diagnostics haven't changed since we last checked.
function! ale#lsp_linter#HandleLSPDiagnostics(conn_id, uri, diagnostics) abort
    let l:linter = get(s:lsp_linter_map, a:conn_id)

    if empty(l:linter)
        return
    endif

    let l:filename = ale#util#ToResource(a:uri)
    let l:escaped_name = escape(
    \   fnameescape(l:filename),
    \   has('win32') ? '^' : '^,}]'
    \)
    let l:buffer = bufnr('^' . l:escaped_name . '$')
    let l:info = get(g:ale_buffer_info, l:buffer, {})

    if empty(l:info)
        return
    endif

    if s:ShouldIgnoreDiagnostics(l:buffer, l:linter)
        return
    endif

    if a:diagnostics is# 'unchanged'
        call ale#engine#MarkLinterInactive(l:info, l:linter)
    else
        let l:loclist = ale#lsp#response#ReadDiagnostics(a:diagnostics)
        call ale#engine#HandleLoclist(l:linter.name, l:buffer, l:loclist, 0)
    endif
endfunction

function! s:HandleTSServerDiagnostics(response, error_type) abort
    " Re-create a fake linter object for tsserver.
    let l:linter = {
    \   'name': 'tsserver',
    \   'aliases': [],
    \   'lsp': 'tsserver',
    \}
    let l:escaped_name = escape(
    \   fnameescape(a:response.body.file),
    \   has('win32') ? '^' : '^,}]'
    \)
    let l:buffer = bufnr('^' . l:escaped_name . '$')
    let l:info = get(g:ale_buffer_info, l:buffer, {})

    if empty(l:info)
        return
    endif

    call ale#engine#MarkLinterInactive(l:info, l:linter.name)

    if s:ShouldIgnoreDiagnostics(l:buffer, l:linter)
        return
    endif

    let l:thislist = ale#lsp#response#ReadTSServerDiagnostics(a:response)
    let l:no_changes = 0

    " tsserver sends syntax and semantic errors in separate messages, so we
    " have to collect the messages separately for each buffer and join them
    " back together again.
    if a:error_type is# 'syntax'
        if len(l:thislist) is 0 && len(get(l:info, 'syntax_loclist', [])) is 0
            let l:no_changes = 1
        endif

        let l:info.syntax_loclist = l:thislist
    elseif a:error_type is# 'semantic'
        if len(l:thislist) is 0 && len(get(l:info, 'semantic_loclist', [])) is 0
            let l:no_changes = 1
        endif

        let l:info.semantic_loclist = l:thislist
    else
        if len(l:thislist) is 0 && len(get(l:info, 'suggestion_loclist', [])) is 0
            let l:no_changes = 1
        endif

        let l:info.suggestion_loclist = l:thislist
    endif

    if l:no_changes
        return
    endif

    let l:loclist = get(l:info, 'semantic_loclist', [])
    \   + get(l:info, 'suggestion_loclist', [])
    \   + get(l:info, 'syntax_loclist', [])

    call ale#engine#HandleLoclist(l:linter.name, l:buffer, l:loclist, 0)
endfunction

function! s:HandleLSPErrorMessage(linter, response) abort
    if !g:ale_history_enabled || !g:ale_history_log_output
        return
    endif

    if empty(a:linter)
        return
    endif

    let l:message = ale#lsp#response#GetErrorMessage(a:response)

    if empty(l:message)
        return
    endif

    call ale#lsp_linter#AddErrorMessage(a:linter.name, l:message)
endfunction

function! ale#lsp_linter#AddErrorMessage(linter_name, message) abort
    " This global variable is set here so we don't load the debugging.vim file
    " until someone uses :ALEInfo.
    let g:ale_lsp_error_messages = get(g:, 'ale_lsp_error_messages', {})

    if !has_key(g:ale_lsp_error_messages, a:linter_name)
        let g:ale_lsp_error_messages[a:linter_name] = []
    endif

    call add(g:ale_lsp_error_messages[a:linter_name], a:message)
endfunction

function! ale#lsp_linter#HandleLSPResponse(conn_id, response) abort
    let l:method = get(a:response, 'method', '')

    if get(a:response, 'jsonrpc', '') is# '2.0' && has_key(a:response, 'error')
        let l:linter = get(s:lsp_linter_map, a:conn_id, {})

        call s:HandleLSPErrorMessage(l:linter, a:response)
    elseif l:method is# 'textDocument/publishDiagnostics'
        let l:uri = a:response.params.uri
        let l:diagnostics = a:response.params.diagnostics

        call ale#lsp_linter#HandleLSPDiagnostics(a:conn_id, l:uri, l:diagnostics)
    elseif has_key(s:diagnostic_uri_map, get(a:response, 'id'))
        let l:uri = remove(s:diagnostic_uri_map, a:response.id)
        let l:diagnostics = a:response.result.kind is# 'unchanged'
        \   ? 'unchanged'
        \   : a:response.result.items

        call ale#lsp_linter#HandleLSPDiagnostics(a:conn_id, l:uri, l:diagnostics)
    elseif l:method is# 'window/showMessage'
        call ale#lsp_window#HandleShowMessage(
        \   s:lsp_linter_map[a:conn_id].name,
        \   g:ale_lsp_show_message_format,
        \   a:response.params
        \)
    elseif get(a:response, 'type', '') is# 'event'
    \&& get(a:response, 'event', '') is# 'semanticDiag'
        call s:HandleTSServerDiagnostics(a:response, 'semantic')
    elseif get(a:response, 'type', '') is# 'event'
    \&& get(a:response, 'event', '') is# 'syntaxDiag'
        call s:HandleTSServerDiagnostics(a:response, 'syntax')
    elseif get(a:response, 'type', '') is# 'event'
    \&& get(a:response, 'event', '') is# 'suggestionDiag'
    \&& get(g:, 'ale_lsp_suggestions')
        call s:HandleTSServerDiagnostics(a:response, 'suggestion')
    endif
endfunction

function! ale#lsp_linter#GetOptions(buffer, linter) abort
    if has_key(a:linter, 'initialization_options_callback')
        return ale#util#GetFunction(a:linter.initialization_options_callback)(a:buffer)
    endif

    if has_key(a:linter, 'initialization_options')
        let l:Options = a:linter.initialization_options

        if type(l:Options) is v:t_func
            let l:Options = l:Options(a:buffer)
        endif

        return l:Options
    endif

    return {}
endfunction

function! ale#lsp_linter#GetConfig(buffer, linter) abort
    if has_key(a:linter, 'lsp_config_callback')
        return ale#util#GetFunction(a:linter.lsp_config_callback)(a:buffer)
    endif

    if has_key(a:linter, 'lsp_config')
        let l:Config = a:linter.lsp_config

        if type(l:Config) is v:t_func
            let l:Config = l:Config(a:buffer)
        endif

        return l:Config
    endif

    return {}
endfunction

function! ale#lsp_linter#FindProjectRoot(buffer, linter) abort
    let l:buffer_ale_root = getbufvar(a:buffer, 'ale_root', {})

    if type(l:buffer_ale_root) is v:t_string
        return l:buffer_ale_root
    endif

    " Try to get a buffer-local setting for the root
    if has_key(l:buffer_ale_root, a:linter.name)
        let l:Root = l:buffer_ale_root[a:linter.name]

        if type(l:Root) is v:t_func
            return l:Root(a:buffer)
        else
            return l:Root
        endif
    endif

    " Try to get a global setting for the root
    if has_key(g:ale_root, a:linter.name)
        let l:Root = g:ale_root[a:linter.name]

        if type(l:Root) is v:t_func
            return l:Root(a:buffer)
        else
            return l:Root
        endif
    endif

    " Fall back to the linter-specific configuration
    if has_key(a:linter, 'project_root')
        let l:Root = a:linter.project_root

        return type(l:Root) is v:t_func ? l:Root(a:buffer) : l:Root
    endif

    return ale#util#GetFunction(a:linter.project_root_callback)(a:buffer)
endfunction

" This function is accessible so tests can call it.
function! ale#lsp_linter#OnInit(linter, details, Callback) abort
    let l:buffer = a:details.buffer
    let l:conn_id = a:details.connection_id
    let l:command = a:details.command

    let l:config = ale#lsp_linter#GetConfig(l:buffer, a:linter)

    call ale#lsp#UpdateConfig(l:conn_id, l:buffer, l:config)

    if ale#lsp#OpenDocument(l:conn_id, l:buffer)
        if g:ale_history_enabled && !empty(l:command)
            call ale#history#Add(l:buffer, 'started', l:conn_id, l:command)
        endif
    endif

    " The change message needs to be sent for tsserver before doing anything.
    if a:linter.lsp is# 'tsserver'
        call ale#lsp#NotifyForChanges(l:conn_id, l:buffer)
    endif

    " Tell the relevant buffer that the LSP has started via an autocmd.
    if l:buffer > 0
        if l:buffer == bufnr('')
            silent doautocmd <nomodeline> User ALELSPStarted
        else
            execute 'augroup ALELSPStartedGroup' . l:buffer
                autocmd!

                execute printf(
                \   'autocmd BufEnter <buffer=%d>'
                \       . ' doautocmd <nomodeline> User ALELSPStarted',
                \   l:buffer
                \)

                " Replicate ++once behavior for backwards compatibility.
                execute printf(
                \   'autocmd BufEnter <buffer=%d>'
                \       . ' autocmd! ALELSPStartedGroup%d',
                \   l:buffer, l:buffer
                \)
            augroup END
        endif
    endif

    call a:Callback(a:linter, a:details)
endfunction

function! s:StartLSP(options, address, executable, command) abort
    let l:buffer = a:options.buffer
    let l:linter = a:options.linter
    let l:root = a:options.root
    let l:Callback = a:options.callback

    let l:init_options = ale#lsp_linter#GetOptions(l:buffer, l:linter)

    if l:linter.lsp is# 'socket'
        let l:conn_id = ale#lsp#Register(
        \   a:address,
        \   l:root,
        \   l:linter.language,
        \   l:init_options
        \)
        let l:ready = ale#lsp#ConnectToAddress(l:conn_id, a:address)
        let l:command = ''
    else
        let l:conn_id = ale#lsp#Register(
        \   a:executable,
        \   l:root,
        \   l:linter.language,
        \   l:init_options
        \)

        " tsserver behaves differently, so tell the LSP API that it is tsserver.
        if l:linter.lsp is# 'tsserver'
            call ale#lsp#MarkConnectionAsTsserver(l:conn_id)
        endif

        let l:cwd = ale#linter#GetCwd(l:buffer, l:linter)
        let l:command = ale#command#FormatCommand(
        \   l:buffer,
        \   a:executable,
        \   a:command,
        \   0,
        \   v:false,
        \   l:cwd,
        \   ale#GetFilenameMappings(l:buffer, l:linter.name),
        \)[1]
        let l:command = ale#job#PrepareCommand(l:buffer, l:command)
        let l:ready = ale#lsp#StartProgram(l:conn_id, a:executable, l:command)
    endif

    if !l:ready
        if g:ale_history_enabled && !empty(a:command)
            call ale#history#Add(l:buffer, 'failed', l:conn_id, a:command)
        endif

        return 0
    endif

    let l:details = {
    \   'buffer': l:buffer,
    \   'connection_id': l:conn_id,
    \   'command': l:command,
    \   'project_root': l:root,
    \}

    call ale#lsp#OnInit(l:conn_id, {->
    \   ale#lsp_linter#OnInit(l:linter, l:details, l:Callback)
    \})

    return 1
endfunction

function! s:StartWithAddress(options, address) abort
    if ale#command#IsDeferred(a:address)
        let a:address.result_callback = {
        \   address -> s:StartWithAddress(a:options, address)
        \}

        return 1
    endif

    if empty(a:address)
        return 0
    endif

    return s:StartLSP(a:options, a:address, '', '')
endfunction

function! s:StartWithCommand(options, executable, command) abort
    if ale#command#IsDeferred(a:command)
        let a:command.result_callback = {
        \   command -> s:StartWithCommand(a:options, a:executable, command)
        \}

        return 1
    endif

    if empty(a:command)
        return 0
    endif

    return s:StartLSP(a:options, '', a:executable, a:command)
endfunction

function! s:StartIfExecutable(options, executable) abort
    if ale#command#IsDeferred(a:executable)
        let a:executable.result_callback = {
        \   executable -> s:StartIfExecutable(a:options, executable)
        \}

        return 1
    endif

    if !ale#engine#IsExecutable(a:options.buffer, a:executable)
        return 0
    endif

    let l:command = ale#linter#GetCommand(a:options.buffer, a:options.linter)

    return s:StartWithCommand(a:options, a:executable, l:command)
endfunction

" Given a buffer, an LSP linter, start up an LSP linter and get ready to
" receive messages for the document.
function! ale#lsp_linter#StartLSP(buffer, linter, Callback) abort
    let l:command = ''
    let l:address = ''
    let l:root = ale#lsp_linter#FindProjectRoot(a:buffer, a:linter)

    if empty(l:root) && a:linter.lsp isnot# 'tsserver'
        " If there's no project root, then we can't check files with LSP,
        " unless we are using tsserver, which doesn't use project roots.
        call ale#lsp_linter#AddErrorMessage(a:linter.name, "Failed to find project root, language server won't start.")

        return 0
    endif

    let l:options = {
    \   'buffer': a:buffer,
    \   'linter': a:linter,
    \   'callback': a:Callback,
    \   'root': l:root,
    \}

    if a:linter.lsp is# 'socket'
        let l:address = ale#linter#GetAddress(a:buffer, a:linter)

        return s:StartWithAddress(l:options, l:address)
    endif

    let l:executable = ale#linter#GetExecutable(a:buffer, a:linter)

    return s:StartIfExecutable(l:options, l:executable)
endfunction

function! s:CheckWithLSP(linter, details) abort
    let l:buffer = a:details.buffer
    let l:info = get(g:ale_buffer_info, l:buffer)

    if empty(l:info)
        return
    endif

    let l:id = a:details.connection_id

    " Register a callback now for handling errors now.
    let l:Callback = function('ale#lsp_linter#HandleLSPResponse')
    call ale#lsp#RegisterCallback(l:id, l:Callback)

    " Remember the linter this connection is for.
    let s:lsp_linter_map[l:id] = a:linter

    if a:linter.lsp is# 'tsserver'
        let l:message = ale#lsp#tsserver_message#Geterr(l:buffer)
        let l:notified = ale#lsp#Send(l:id, l:message) != 0

        if l:notified
            call ale#engine#MarkLinterActive(l:info, a:linter)
        endif
    elseif !g:ale_use_neovim_lsp_api
        let l:notified = ale#lsp#NotifyForChanges(l:id, l:buffer)

        " If this was a file save event, also notify the server of that.
        if getbufvar(l:buffer, 'ale_save_event_fired', 0)
        \&& ale#lsp#HasCapability(l:id, 'did_save')
            let l:include_text = ale#lsp#HasCapability(l:id, 'includeText')
            let l:save_message = ale#lsp#message#DidSave(l:buffer, l:include_text)
            let l:notified = ale#lsp#Send(l:id, l:save_message) != 0
        endif

        let l:diagnostic_request_id = 0

        " If the document is updated and we can pull diagnostics, try to.
        if ale#lsp#HasCapability(l:id, 'pull_model')
            let l:diagnostic_message = ale#lsp#message#Diagnostic(l:buffer)

            let l:diagnostic_request_id = ale#lsp#Send(l:id, l:diagnostic_message)
        endif

        " If we are going to pull diagnostics, then mark the linter as active,
        " and remember the URI we sent the request for.
        if l:diagnostic_request_id
            call ale#engine#MarkLinterActive(l:info, a:linter)
            let s:diagnostic_uri_map[l:diagnostic_request_id] =
            \   l:diagnostic_message[2].textDocument.uri
        endif
    endif
endfunction

function! ale#lsp_linter#CheckWithLSP(buffer, linter) abort
    return ale#lsp_linter#StartLSP(a:buffer, a:linter, function('s:CheckWithLSP'))
endfunction

function! s:HandleLSPResponseToCustomRequests(conn_id, response) abort
    if has_key(a:response, 'id')
        " Get the custom handlers Dictionary from the linter map.
        let l:linter = get(s:lsp_linter_map, a:conn_id, {})
        let l:custom_handlers = get(l:linter, 'custom_handlers', {})

        if has_key(l:custom_handlers, a:response.id)
            let l:Handler = remove(l:custom_handlers, a:response.id)
            call l:Handler(a:response)
        endif
    endif
endfunction

function! s:OnReadyForCustomRequests(args, linter, lsp_details) abort
    let l:id = a:lsp_details.connection_id
    let l:request_id = ale#lsp#Send(l:id, a:args.message)

    if l:request_id > 0 && has_key(a:args, 'handler')
        let l:Callback = function('s:HandleLSPResponseToCustomRequests')
        call ale#lsp#RegisterCallback(l:id, l:Callback)

        " Remember the linter this connection is for.
        let s:lsp_linter_map[l:id] = a:linter

        " Add custom_handlers to the linter Dictionary.
        if !has_key(a:linter, 'custom_handlers')
            let a:linter.custom_handlers = {}
        endif

        " Put the handler function in the map to call later.
        let a:linter.custom_handlers[l:request_id] = a:args.handler
    endif
endfunction

" Send a custom request to an LSP linter.
function! ale#lsp_linter#SendRequest(buffer, linter_name, message, ...) abort
    let l:filetype = ale#linter#ResolveFiletype(getbufvar(a:buffer, '&filetype'))
    let l:linter_list = ale#linter#GetAll(l:filetype)
    let l:linter_list = filter(l:linter_list, {_, v -> v.name is# a:linter_name})

    if len(l:linter_list) < 1
        throw 'Linter "' . a:linter_name . '" not found!'
    endif

    let l:linter = l:linter_list[0]

    if empty(l:linter.lsp)
        throw 'Linter "' . a:linter_name . '" does not support LSP!'
    endif

    let l:is_notification = a:message[0]
    let l:callback_args = {'message': a:message}

    if !l:is_notification && a:0
        let l:callback_args.handler = a:1
    endif

    let l:Callback = function('s:OnReadyForCustomRequests', [l:callback_args])

    return ale#lsp_linter#StartLSP(a:buffer, l:linter, l:Callback)
endfunction
