package apperr

import "fmt"

// Code is a stable API error code.
type Code string

const (
	Unauthorized            Code = "UNAUTHORIZED"
	AuthInvalidCredentials  Code = "AUTH_INVALID_CREDENTIALS"
	UsernameTaken           Code = "USERNAME_TAKEN"
	RegisterDisabled        Code = "REGISTER_DISABLED"
	InviteInvalid           Code = "INVITE_INVALID"
	UserDisabled            Code = "USER_DISABLED"
	UploadHashMismatch      Code = "UPLOAD_HASH_MISMATCH"
	UploadIncomplete        Code = "UPLOAD_INCOMPLETE"
	UploadTooLarge          Code = "UPLOAD_TOO_LARGE"
	InsufficientStorage     Code = "INSUFFICIENT_STORAGE"
	DerivativePending       Code = "DERIVATIVE_PENDING"
	ShareInvalid            Code = "SHARE_INVALID"
	ShareExpired            Code = "SHARE_EXPIRED"
	ShareRevoked            Code = "SHARE_REVOKED"
	ShareScopeInvalid       Code = "SHARE_SCOPE_INVALID"
	SharePasswordRequired   Code = "SHARE_PASSWORD_REQUIRED"
	NotFound                Code = "NOT_FOUND"
	BadRequest              Code = "BAD_REQUEST"
	Internal                Code = "INTERNAL"
	SMSDisabled             Code = "SMS_DISABLED"
	SMSCodeInvalid          Code = "SMS_CODE_INVALID"
)

// Error is an application-level error with stable code.
type Error struct {
	Code    Code
	Message string
	Err     error
}

func (e *Error) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("%s: %s: %v", e.Code, e.Message, e.Err)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func (e *Error) Unwrap() error { return e.Err }

func New(code Code, message string) *Error {
	return &Error{Code: code, Message: message}
}

func Wrap(code Code, message string, err error) *Error {
	return &Error{Code: code, Message: message, Err: err}
}

func As(err error) (*Error, bool) {
	if err == nil {
		return nil, false
	}
	if e, ok := err.(*Error); ok {
		return e, true
	}
	return nil, false
}
