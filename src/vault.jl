# PIN-protected credential vault. The decrypted values live only while a
# dashboard action is executing; no agent-facing tool can unlock this vault.

const VAULT_VERSION = 1
const VAULT_SALT_BYTES = 16
const VAULT_NONCE_BYTES = 24             # XChaCha20-Poly1305 nonce
const VAULT_KEY_BYTES = 32
const VAULT_OPSLIMIT = Culonglong(2)     # Argon2id interactive profile
const VAULT_MEMLIMIT = Csize_t(64 * 1024 * 1024)
const VAULT_ARGON2ID13 = Cint(2)
const SODIUM = libsodium_jll.libsodium

function sodium_init!()
    ccall((:sodium_init, SODIUM), Cint, ()) >= 0 || error("libsodium could not initialise")
    return nothing
end

function sodium_random(n::Integer)
    bytes = Vector{UInt8}(undef, n)
    ccall((:randombytes_buf, SODIUM), Cvoid, (Ptr{Cvoid}, Csize_t), bytes, length(bytes))
    return bytes
end

function sodium_wipe!(bytes::Vector{UInt8})
    isempty(bytes) || ccall((:sodium_memzero, SODIUM), Cvoid, (Ptr{Cvoid}, Csize_t), bytes, length(bytes))
    return nothing
end

function vault_key(pin::AbstractString, salt::Vector{UInt8})
    length(salt) == VAULT_SALT_BYTES || throw(AppError("the credential vault is corrupted (bad salt)"))
    password = Vector{UInt8}(codeunits(pin))
    isempty(password) && throw(AppError("enter the Community PIN"))
    key = Vector{UInt8}(undef, VAULT_KEY_BYTES)
    try
        ok = ccall((:crypto_pwhash, SODIUM), Cint,
                   (Ptr{UInt8}, Culonglong, Ptr{UInt8}, Culonglong, Ptr{UInt8}, Culonglong, Csize_t, Cint),
                   key, length(key), password, length(password), salt, VAULT_OPSLIMIT, VAULT_MEMLIMIT, VAULT_ARGON2ID13)
        ok == 0 || throw(AppError("could not derive the credential-vault key"))
        return key
    finally
        sodium_wipe!(password)
    end
end

function vault_encrypt(key::Vector{UInt8}, plain::Vector{UInt8})
    nonce = sodium_random(VAULT_NONCE_BYTES)
    out = Vector{UInt8}(undef, length(plain) + 16)
    outlen = Ref{Culonglong}(0)
    ok = ccall((:crypto_aead_xchacha20poly1305_ietf_encrypt, SODIUM), Cint,
               (Ptr{UInt8}, Ref{Culonglong}, Ptr{UInt8}, Culonglong, Ptr{UInt8}, Culonglong, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}),
               out, outlen, plain, length(plain), C_NULL, 0, C_NULL, nonce, key)
    ok == 0 || error("could not encrypt credential vault")
    resize!(out, Int(outlen[]))
    return nonce, out
end

function vault_decrypt(key::Vector{UInt8}, nonce::Vector{UInt8}, cipher::Vector{UInt8})
    length(nonce) == VAULT_NONCE_BYTES || throw(AppError("the credential vault is corrupted (bad nonce)"))
    out = Vector{UInt8}(undef, max(0, length(cipher) - 16))
    outlen = Ref{Culonglong}(0)
    ok = ccall((:crypto_aead_xchacha20poly1305_ietf_decrypt, SODIUM), Cint,
               (Ptr{UInt8}, Ref{Culonglong}, Ptr{Cvoid}, Ptr{UInt8}, Culonglong, Ptr{UInt8}, Culonglong, Ptr{UInt8}, Ptr{UInt8}),
               out, outlen, C_NULL, cipher, length(cipher), C_NULL, 0, nonce, key)
    ok == 0 || throw(AppError("incorrect Community PIN"))
    resize!(out, Int(outlen[]))
    return out
end

vault_exists(app) = isfile(app.secrets_file)
vault_active(app) = app.active_secrets[] !== nothing
legacy_secrets_file(app) = joinpath(dirname(app.secrets_file), "secrets.json")

function vault_envelope(pin::AbstractString, secrets::Dict{String,String})
    salt = sodium_random(VAULT_SALT_BYTES)
    key = vault_key(pin, salt)
    plain = Vector{UInt8}(codeunits(JSON.json(secrets)))
    try
        nonce, cipher = vault_encrypt(key, plain)
        return Dict("version" => VAULT_VERSION, "salt" => base64encode(salt), "nonce" => base64encode(nonce),
                    "ciphertext" => base64encode(cipher))
    finally
        sodium_wipe!(key); sodium_wipe!(plain)
    end
end

function write_vault!(app, pin::AbstractString, secrets::Dict{String,String})
    atomic_write_json(app.secrets_file, vault_envelope(pin, secrets))
    chmod(app.secrets_file, 0o600)
    return nothing
end

function read_vault(app, pin::AbstractString)
    raw = load_json_tolerant(app.secrets_file, "encrypted community credentials")
    raw === nothing && throw(AppError("set a Community PIN before adding accounts"))
    Int(get(raw, "version", 0)) == VAULT_VERSION || throw(AppError("the credential vault has an unsupported format"))
    salt = try base64decode(String(raw["salt"])) catch; throw(AppError("the credential vault is corrupted")) end
    nonce = try base64decode(String(raw["nonce"])) catch; throw(AppError("the credential vault is corrupted")) end
    cipher = try base64decode(String(raw["ciphertext"])) catch; throw(AppError("the credential vault is corrupted")) end
    key = vault_key(pin, salt)
    plain = try vault_decrypt(key, nonce, cipher) finally sodium_wipe!(key) end
    try
        decoded = JSON.parse(String(plain))
        decoded isa AbstractDict || throw(AppError("the credential vault is corrupted"))
        return Dict{String,String}(String(k) => String(v) for (k, v) in decoded)
    finally
        sodium_wipe!(plain)
    end
end

function wipe_secrets!(secrets::Dict{String,String})
    # Julia strings cannot be reliably zeroed; remove all app references at the
    # end of this request. The durable file is always authenticated-encrypted.
    empty!(secrets)
    return nothing
end

"Run one explicit, PIN-authorised dashboard operation. Never call from an agent tool."
function with_vault!(f, app, pin::AbstractString)
    lock(app.lock) do
        app.active_secrets[] === nothing || throw(AppError("another credential operation is already in progress"))
        secrets = read_vault(app, pin)
        app.active_secrets[] = secrets
        try
            result = f()
            # Re-encrypt even a read-only operation: each authorised use gets a
            # fresh salt and nonce, and mutations become durable atomically.
            write_vault!(app, pin, secrets)
            return result
        finally
            app.active_secrets[] = nothing
            empty!(app.sessions)
            wipe_secrets!(secrets)
        end
    end
end

function create_vault!(app, pin::AbstractString)
    vault_exists(app) && throw(AppError("a Community PIN is already set"))
    legacy = legacy_secrets_file(app)
    write_vault!(app, pin, Dict{String,String}())
    if isfile(legacy)
        # This is intentionally not a credential migration. A new PIN starts
        # from an empty vault; the legacy file is only an obsolete empty/test
        # credential file on a first production setup.
        open(legacy, "r+") do io
            write(io, zeros(UInt8, filesize(legacy)))
            flush(io)
        end
        rm(legacy; force = true)
    end
    notify(app.state)             # redraw the account cards as unlocked-for-setup
    return nothing
end
