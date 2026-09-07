package middleware

import (
	"strings"

	"github.com/fengtianyu/memorystore/server/internal/auth"
	"github.com/fengtianyu/memorystore/server/internal/httpapi/respond"
	"github.com/fengtianyu/memorystore/server/pkg/apperr"
	"github.com/gin-gonic/gin"
)

const CtxUserKey = "authed_user"

func RequireUser(authSvc *auth.Service) gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			respond.Fail(c, apperr.New(apperr.Unauthorized, "missing bearer token"))
			c.Abort()
			return
		}
		token := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
		u, err := authSvc.Authenticate(c.Request.Context(), token)
		if err != nil {
			respond.Fail(c, err)
			c.Abort()
			return
		}
		c.Set(CtxUserKey, u)
		c.Next()
	}
}

func User(c *gin.Context) *auth.AuthedUser {
	v, ok := c.Get(CtxUserKey)
	if !ok {
		return nil
	}
	u, _ := v.(*auth.AuthedUser)
	return u
}
