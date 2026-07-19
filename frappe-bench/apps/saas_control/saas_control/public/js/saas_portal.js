(function () {
	function byId(id) {
		return document.getElementById(id);
	}

	function setNotice(text, isError) {
		var notice = byId("saas-notice");
		notice.textContent = text || "";
		notice.classList.toggle("hidden", !text);
		notice.classList.toggle("error", !!isError);
	}

	function toggleSignup(show) {
		byId("signup-fields").classList.toggle("hidden", !show);
		byId("create-btn").classList.toggle("hidden", !show);
	}

	async function callApi(methodPath, payload) {
		var headers = { "Content-Type": "application/json" };
		if (window.csrf_token) {
			headers["X-Frappe-CSRF-Token"] = window.csrf_token;
		}

		var response = await fetch("/api/method/" + methodPath, {
			method: "POST",
			headers: headers,
			body: JSON.stringify(payload),
		});

		var data = await response.json();
		if (!response.ok || data.exc) {
			throw new Error((data && data._server_messages) || "API request failed");
		}

		return data.message || {};
	}

	async function handleContinue() {
		setNotice("");
		toggleSignup(false);

		var email = byId("email").value.trim();
		if (!email) {
			setNotice("Enter your email to continue.", true);
			return;
		}

		byId("continue-btn").disabled = true;
		try {
			var result = await callApi("saas_control.saas_control.api.resolve_tenant", {
				email: email,
			});
			if (result.found && result.redirect_url) {
				setNotice("Tenant found. Redirecting to login...");
				window.location.href = result.redirect_url;
				return;
			}

			setNotice("No active tenant found. Complete signup fields to create a new tenant.");
			toggleSignup(true);
		} catch (error) {
			setNotice("Unable to resolve tenant right now.", true);
		} finally {
			byId("continue-btn").disabled = false;
		}
	}

	async function handleCreateTenant() {
		setNotice("");

		var email = byId("email").value.trim();
		var fullName = byId("full_name").value.trim();
		var companySlug = byId("company_slug").value.trim();
		var password = byId("password").value;

		if (!email || !fullName || !companySlug || !password) {
			setNotice("Fill in all signup fields.", true);
			return;
		}

		byId("create-btn").disabled = true;
		try {
			var result = await callApi("saas_control.saas_control.api.create_or_login", {
				email: email,
				full_name: fullName,
				company_slug: companySlug,
				password: password,
			});

			if (result.redirect_url) {
				setNotice("Tenant ready. Redirecting to login...");
				window.location.href = result.redirect_url;
				return;
			}

			setNotice("Tenant created but redirect URL missing.", true);
		} catch (error) {
			setNotice("Tenant creation failed. Try a different company slug.", true);
		} finally {
			byId("create-btn").disabled = false;
		}
	}

	function wireEvents() {
		byId("continue-btn").addEventListener("click", function (event) {
			event.preventDefault();
			handleContinue();
		});

		byId("create-btn").addEventListener("click", function (event) {
			event.preventDefault();
			handleCreateTenant();
		});
	}

	document.addEventListener("DOMContentLoaded", wireEvents);
})();
