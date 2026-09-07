package respond

import (
	"errors"
	"net/http"

	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/gin-gonic/gin"
)

type envelope struct {
	OK    bool     `json:"ok"`
	Data  any      `json:"data"`
	Error *errBody `json:"error"`
}

type errBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func OK(c *gin.Context, data any) {
	c.JSON(http.StatusOK, envelope{OK: true, Data: data})
}

func Fail(c *gin.Context, err error) {
	var ae *apperr.Error
	if errors.As(err, &ae) {
		c.JSON(statusOf(ae.Code), envelope{
			OK:    false,
			Error: &errBody{Code: string(ae.Code), Message: ae.Message},
		})
		return
	}
	c.JSON(http.StatusInternalServerError, envelope{
		OK:    false,
		Error: &errBody{Code: string(apperr.Internal), Message: "internal error"},
	})
}

func statusOf(code apperr.Code) int {
	switch code {
	case apperr.Unauthorized, apperr.AuthInvalidCredentials, apperr.ShareInvalid:
		return http.StatusUnauthorized
	case apperr.RegisterDisabled, apperr.UserDisabled, apperr.ShareExpired, apperr.ShareRevoked, apperr.SharePasswordRequired:
		return http.StatusForbidden
	case apperr.UsernameTaken:
		return http.StatusConflict
	case apperr.NotFound, apperr.DerivativePending:
		return http.StatusNotFound
	case apperr.UploadTooLarge:
		return http.StatusRequestEntityTooLarge
	case apperr.InsufficientStorage:
		return http.StatusInsufficientStorage
	case apperr.SMSDisabled:
		return http.StatusServiceUnavailable
	default:
		return http.StatusBadRequest
	}
}
